object frmMain: TfrmMain
  Left = 0
  Top = 0
  Caption = 'Ultimanium Digital Audio Workstation (UDAW)'
  ClientHeight = 620
  ClientWidth = 960
  Color = clBtnFace
  DoubleBuffered = True
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  KeyPreview = True
  OnCreate = FormCreate
  OnClose = FormClose
  OnDestroy = FormDestroy
  OnKeyDown = FormKeyDown
  OnKeyUp = FormKeyUp
  OnResize = FormResize
  TextHeight = 15
  object mbMain: TGLMenuBar
    Left = 0
    Top = 0
    Width = 960
    Height = 24
    Align = alTop
    Menu = mnuMain
  end
  object pnlTop: TGLPanel
    Left = 0
    Top = 24
    Width = 960
    Height = 3
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
  end
  object pgc: TGLPageControl
    Left = 0
    Top = 27
    Width = 960
    Height = 574
    ActivePage = tabTimeline
    Align = alClient
    MultiLine = True
    TabOrder = 1
    OnChange = pgcChange
    OnResize = pgcResize
    object bvlTlMasterSep: TGLBevel
      Left = 300
      Top = 4
      Width = 2
      Height = 20
      Shape = bsLeftLine
    end
    object lblTlMasterVol: TGLLabel
      Transparent = True
      Left = 314
      Top = 6
      Width = 150
      Height = 15
      Caption = 'Master Vol  0.0 dB'
    end
    object tbTlMasterVol: TGLTrackBar
      Left = 470
      Top = 3
      Width = 120
      Height = 22
      Max = 12
      Min = -60
      Position = 0
      TabOrder = 3
      ThumbLength = 12
      OnChange = tbTlMasterVolChange
    end
    object pbTlMeters: TGLView
      Left = 600
      Top = 2
      Width = 164
      Height = 24
      OnPaint = pbTlMetersPaint
    end
    object tabTimeline: TGLPage
      Caption = 'Timeline'
      ImageIndex = 8
      object pnlTimelineTop: TGLPanel
        Left = 0
        Top = 0
        Width = 952
        Height = 64
        Align = alTop
        BevelOuter = bvNone
        BevelKind = bkFlat
        BevelEdges = [beBottom]
        TabOrder = 0
        object ibTlTransport: TGLIconBar
          Left = 8
          Top = 16
          Width = 463
          Height = 32
          ShowHint = True
          Buttons = 'tostart;play;stop;toend;record;loop;video;editor;stage;browser;metronome;lanes;chords;foley;deletecache'
          Hints = 'Go to the start of the Timeline;Play from the playhead (Space);Stop playback;Go to the end of the Timeline;Record: open the Recording view to arm tracks and record takes;Loop: repeat the loop region while playing;Video: show or hide the video playback panel (lit = shown);Editor: show or hide the editor under the Timeline - piano roll, mixer, tracker, recording (lit = shown);Clip Stage: show or hide the Clip Stage - patterns as scenes, one launch slot per track (lit = shown);Browser: show or hide the browser panel - instruments, effects, samples and presets (lit = shown);Metronome: a click on every beat while the Timeline plays (lit = on);Lanes: show or hide the Markers, Tempo and Signature lanes under the ruler (lit = shown);Chords: show or hide the Chords lane under the Markers lane - chord symbols over the Timeline (lit = shown);Foley: show or hide the Foley Sampler under the Timeline - sixteen sound-effect pads you can play, record against the picture and add to the Timeline (lit = shown);Delete Cache: removes the files in the local cache folder that are NOT used by this project (or your recent projects)'
          OnButtonClick = ibTlTransportClick
        end
        object bvlTlSep1: TGLBevel
          Left = 481
          Top = 8
          Width = 2
          Height = 48
          Shape = bsLeftLine
        end
        object lblTlTime: TGLLabel
          Transparent = True
          Left = 495
          Top = 8
          Width = 150
          Height = 28
          Caption = '00:00.000'
          Font.Height = -24
          Font.Name = 'Consolas'
          Font.Style = [fsBold]
          ParentFont = False
        end
        object lblTlTimeCap: TGLLabel
          Transparent = True
          Left = 497
          Top = 40
          Width = 28
          Height = 13
          Caption = 'TIME'
          Font.Height = -11
          ParentFont = False
        end
        object lblTlBars: TGLLabel
          Transparent = True
          Left = 659
          Top = 8
          Width = 110
          Height = 28
          Caption = '1.1.000'
          Font.Height = -24
          Font.Name = 'Consolas'
          Font.Style = [fsBold]
          ParentFont = False
        end
        object lblTlBarsCap: TGLLabel
          Transparent = True
          Left = 661
          Top = 40
          Width = 30
          Height = 13
          Caption = 'BARS'
          Font.Height = -11
          ParentFont = False
        end
        object edtTlTempo: TGLEdit
          Left = 783
          Top = 12
          Width = 64
          Height = 26
          TabOrder = 2
          Text = '120'
          OnExit = edtTlTempoExit
        end
        object lblTlTempo: TGLLabel
          Transparent = True
          Left = 785
          Top = 40
          Width = 24
          Height = 13
          Caption = 'BPM'
          Font.Height = -11
          ParentFont = False
        end
        object bvlTlSep2: TGLBevel
          Left = 861
          Top = 8
          Width = 2
          Height = 48
          Shape = bsLeftLine
        end
        object lblTlSnap: TGLLabel
          Transparent = True
          Left = 875
          Top = 40
          Width = 30
          Height = 13
          Caption = 'SNAP'
          Font.Height = -11
          ParentFont = False
        end
        object cboTlSnap: TGLCombo
          Left = 875
          Top = 12
          Width = 150
          Height = 26
          TabOrder = 0
          OnChange = cboTlSnapChange
        end
      end
      object pnlTlMode: TGLPanel
        Left = 0
        Top = 64
        Width = 952
        Height = 34
        Align = alTop
        BevelOuter = bvNone
        TabOrder = 7
        object tsTlMode: TGLTabStrip
          CurvedTabs = True
          Left = 8
          Top = 3
          Width = 800
          Height = 28
          Tabs = 'TIMELINE;PIANO;SCORE;INST;PATTERN;MIX;TRACKER;REC;AI/SI;FOLEY'
          Hints = 'Timeline: the lanes, tracks and clips;Piano: the piano roll for the selected MIDI clip, with the chord lane;Score: the selected MIDI tracks as music notation;Inst: the drum machine - sample pads on every MIDI note, 16 at a time;Pattern: the step sequencer for rhythm patterns - saved in the project and placed on the Timeline as clips;Mix: the channel strips, faders and effects;Tracker: tracker patterns and instruments;Rec: record takes and comp them;AI: providers, prompts and generation;Foley: sixteen sound-effect pads to play, record against the picture and add to the Timeline'
          OnChange = tsTlModeChange
        end
      end
      object pnlTlViews: TGLRecessPanel
        Left = 0
        Top = 98
        Width = 952
        Height = 32
        Align = alTop
        BevelOuter = bvNone
        TabOrder = 6
        object lblTlArr: TGLLabel
          Transparent = True
          Left = 12
          Top = 8
          Width = 80
          Height = 15
          Caption = 'Timeline'
          Font.Style = [fsBold]
          ParentFont = False
        end
        object ibTlTools: TGLIconBar
          Left = 112
          Top = 2
          Width = 124
          Height = 28
          ShowHint = True
          Buttons = 'select;range;split;erase'
          Hints = 'Select: click and drag clips, drag on empty space to select a time range;Range: drag anywhere in the lanes to select a time range;Split: click a clip to cut it at the pointer (snapped);Erase: click a clip to delete it'
          OnButtonClick = ibTlToolsClick
        end
        object bvlTlSep4: TGLBevel
          Left = 248
          Top = 4
          Width = 2
          Height = 24
          Shape = bsLeftLine
        end
        object cboTlStageQuant: TGLCombo
          Left = 262
          Top = 4
          Width = 90
          Height = 24
          Hint = 'Launch quantize: launched clips start on this grid'
          ItemIndex = 2
          ParentShowHint = False
          ShowHint = True
          TabOrder = 92
          OnChange = cboTlStageQuantChange
          Items.Strings = (
            'None'
            '1 beat'
            '1 bar'
            '2 bars'
            '4 bars')
        end
        object ibTlStage: TGLIconBar
          Left = 360
          Top = 2
          Width = 34
          Height = 28
          ShowHint = True
          Buttons = 'back'
          Hints = 'Back to Timeline: end every Clip Stage override so the tracks play the Timeline again'
          OnButtonClick = ibTlStageClick
        end
        object bvlTlSep5: TGLBevel
          Left = 406
          Top = 4
          Width = 2
          Height = 24
          Shape = bsLeftLine
        end
      end
      object pnlTlDock: TGLPanel
        Left = 0
        Top = 400
        Width = 952
        Height = 380
        Align = alBottom
        BevelOuter = bvNone
        TabOrder = 5
        Visible = False
        object sbTlDock: TGLScrollBox
          Left = 0
          Top = 0
          Width = 952
          Height = 380
          Align = alClient
          TabOrder = 0
          ContentPadding = 0
          OnResize = sbTlDockResize
          object pgcDock: TGLPageControl
            Left = 0
            Top = 0
            Width = 940
            Height = 372
            ActivePage = tabMixer
            TabOrder = 0
            OnChange = pgcDockChange
            object tabMixer: TGLPage
              Caption = 'Mixer'
              ImageIndex = 11
              DoubleBuffered = True
              ParentDoubleBuffered = False
              object pnlMixBar: TGLPanel
                Left = 0
                Top = 0
                Width = 952
                Height = 30
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 3
                object ibMixBar: TGLIconBar
                  Left = 8
                  Top = 1
                  Width = 240
                  Height = 28
                  ShowHint = True
                  Buttons = 'add;tools;undo;redo;zoomout;zoomin;left;right'
                  Hints = 'Add: a track, bus, aux or VCA strip (more on the strip right-click menu);Strip tools: show or hide the detailed strip, automation and meter settings;Undo the last mixer change;Redo the mixer change;Narrower strips;Wider strips;Scroll the strips left;Scroll the strips right'
                  OnButtonClick = ibMixBarClick
                end
                object bvlMixSep: TGLBevel
                  Left = 256
                  Top = 4
                  Width = 2
                  Height = 22
                  Shape = bsLeftLine
                end
                object cboMixView: TGLCombo
                  Left = 266
                  Top = 3
                  Width = 120
                  Height = 24
                  Hint = 'Which mixer to show: the Timeline strips, or the Tracker channel strips (TRK-CHN) with their EQ and Master'
                  TabOrder = 1
                  Items.Strings = (
                    'Timeline'
                    'Tracker')
                  ItemIndex = 0
                  OnChange = cboMixViewChange
                end
              end
              object pnlMixTop: TGLPanel
                Left = 0
                Top = 30
                Width = 952
                Height = 172
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                Visible = False
                object lblMixStrip: TGLLabel
                  Transparent = True
                  Left = 8
                  Top = 12
                  Width = 27
                  Height = 15
                  Caption = 'Strip'
                end
                object lblMixFader: TGLLabel
                  Transparent = True
                  Left = 8
                  Top = 46
                  Width = 47
                  Height = 15
                  Caption = 'Fader dB'
                end
                object lblMixPan: TGLLabel
                  Transparent = True
                  Left = 128
                  Top = 46
                  Width = 20
                  Height = 15
                  Caption = 'Pan'
                end
                object lblMixRoute: TGLLabel
                  Transparent = True
                  Left = 488
                  Top = 12
                  Width = 46
                  Height = 15
                  Caption = 'Route to'
                end
                object cboMixStrip: TGLCombo
                  Left = 44
                  Top = 8
                  Width = 180
                  Height = 23
                  TabOrder = 0
                  OnChange = cboMixStripChange
                end
                object lblMixTrackLink: TGLLabel
                  Transparent = True
                  Left = 236
                  Top = 12
                  Width = 49
                  Height = 15
                  Caption = 'Link track'
                end
                object cboMixTrackLink: TGLCombo
                  Left = 296
                  Top = 8
                  Width = 180
                  Height = 23
                  TabOrder = 21
                  OnChange = cboMixTrackLinkChange
                end
                object edtMixFader: TGLEdit
                  Left = 64
                  Top = 42
                  Width = 52
                  Height = 23
                  TabOrder = 6
                  Text = '0'
                end
                object edtMixPan: TGLEdit
                  Left = 156
                  Top = 42
                  Width = 52
                  Height = 23
                  TabOrder = 7
                  Text = '0'
                end
                object chkMixMute: TGLCheck
                  Left = 224
                  Top = 44
                  Width = 52
                  Height = 17
                  Caption = 'Mute'
                  TabOrder = 8
                  OnClick = chkMixMuteClick
                end
                object chkMixSolo: TGLCheck
                  Left = 284
                  Top = 44
                  Width = 52
                  Height = 17
                  Caption = 'Solo'
                  TabOrder = 9
                  OnClick = chkMixSoloClick
                end
                object cboMixRoute: TGLCombo
                  Left = 540
                  Top = 8
                  Width = 160
                  Height = 23
                  TabOrder = 10
                end
                object cboMixInsertKind: TGLCombo
                  Left = 8
                  Top = 76
                  Width = 170
                  Height = 23
                  TabOrder = 12
                end
                object btnMixAddVST: TGLButton
                  Left = 596
                  Top = 75
                  Width = 110
                  Height = 25
                  Caption = 'Add VST...'
                  TabOrder = 13
                  OnClick = btnMixAddVSTClick
                end
                object btnMixEditVST: TGLButton
                  Left = 712
                  Top = 75
                  Width = 110
                  Height = 25
                  Caption = 'Edit VST...'
                  TabOrder = 14
                  OnClick = btnMixEditVSTClick
                end
                object lblMixAutoParam: TGLLabel
                  Transparent = True
                  Left = 352
                  Top = 46
                  Width = 30
                  Height = 15
                  Caption = 'Auto'
                end
                object cboMixAutoParam: TGLCombo
                  Left = 386
                  Top = 42
                  Width = 190
                  Height = 23
                  TabOrder = 15
                  OnChange = cboMixAutoParamChange
                end
                object cboMixAutoMode: TGLCombo
                  Left = 584
                  Top = 42
                  Width = 100
                  Height = 23
                  TabOrder = 16
                  OnChange = cboMixAutoModeChange
                end
                object lblMixZoom: TGLLabel
                  Transparent = True
                  Left = 8
                  Top = 112
                  Width = 60
                  Height = 15
                  Caption = 'Strip width'
                end
                object tbMixZoom: TGLTrackBar
                  Left = 76
                  Top = 104
                  Width = 140
                  Height = 30
                  Max = 20
                  Min = 5
                  Position = 10
                  TabOrder = 17
                  OnChange = tbMixZoomChange
                end
                object lblMixMasterLoudness: TGLLabel
                  Transparent = True
                  Left = 724
                  Top = 8
                  Width = 220
                  Height = 40
                  Caption = 'Master:  -inf dBFS   M -inf LUFS   I -inf LUFS'
                  WordWrap = True
                end
                object lblMixMeterHold: TGLLabel
                  Transparent = True
                  Left = 240
                  Top = 112
                  Width = 44
                  Height = 15
                  Caption = 'Hold ms'
                end
                object lblMixMeterDecay: TGLLabel
                  Transparent = True
                  Left = 356
                  Top = 112
                  Width = 52
                  Height = 15
                  Caption = 'Decay dB/s'
                end
                object edtMixMeterHold: TGLEdit
                  Left = 292
                  Top = 108
                  Width = 48
                  Height = 23
                  TabOrder = 18
                  Text = '1500'
                end
                object edtMixMeterDecay: TGLEdit
                  Left = 424
                  Top = 108
                  Width = 48
                  Height = 23
                  TabOrder = 19
                  Text = '10'
                end
                object btnMixMeterApply: TGLButton
                  Left = 480
                  Top = 107
                  Width = 48
                  Height = 25
                  Caption = 'Set'
                  TabOrder = 20
                  OnClick = btnMixMeterApplyClick
                end
                object btnMixAddInsertRow: TGLButton
                  Left = 186
                  Top = 75
                  Width = 90
                  Height = 25
                  Caption = 'Add insert'
                  TabOrder = 22
                  OnClick = btnMixAddEQClick
                end
                object btnMixDelInsertRow: TGLButton
                  Left = 282
                  Top = 75
                  Width = 100
                  Height = 25
                  Caption = 'Remove insert'
                  TabOrder = 23
                  OnClick = btnMixDelInsertClick
                end
                object btnMixApplyRow: TGLButton
                  Left = 388
                  Top = 75
                  Width = 64
                  Height = 25
                  Caption = 'Apply'
                  TabOrder = 24
                  OnClick = btnMixApplyClick
                end
                object btnMixUndoRow: TGLButton
                  Left = 458
                  Top = 75
                  Width = 56
                  Height = 25
                  Caption = 'Undo'
                  TabOrder = 25
                  OnClick = btnMixUndoClick
                end
                object btnMixRedoRow: TGLButton
                  Left = 520
                  Top = 75
                  Width = 56
                  Height = 25
                  Caption = 'Redo'
                  TabOrder = 26
                  OnClick = btnMixRedoClick
                end
                object pbMixAuto: TGLView
                  Left = 0
                  Top = 138
                  Width = 952
                  Height = 34
                  OnMouseDown = pbMixAutoMouseDown
                  OnMouseMove = pbMixAutoMouseMove
                  OnMouseUp = pbMixAutoMouseUp
                  OnPaint = pbMixAutoPaint
                end
              end
              object pbMixer: TGLView
                Left = 0
                Top = 30
                Width = 952
                Height = 341
                Align = alClient
                PopupMenu = pmMixer
                OnDragDrop = pbMixerDragDrop
                OnDragOver = pbMixerDragOver
                OnMouseWheel = pbMixerMouseWheel
                OnPaint = pbMixerPaint
                object sbMixH: TGLScrollBar
                  Left = 0
                  Top = 325
                  Width = 952
                  Height = 16
                  Visible = False
                  Kind = sbHorizontal
                  PageSize = 0
                  TabOrder = 1
                  OnChange = sbMixHChange
                end
                object pnlMixEq: TGLCollapsePanel
                  Left = 340
                  Top = 4
                  Width = 616
                  Height = 241
                  BevelOuter = bvNone
                  TabOrder = 0
                  Title = 'Master Graphic 16-Band EQ'
                HeadHeight = 42
                  AutoPlace = False
                  OnToggle = MixEqToggle
                  Hint = 'Graphic equaliser on the Master output. Click the title bar to collapse or expand it.'
                  object cboMixEqPreset: TGLCombo
                    Left = 368
                    Top = 10
                    Width = 150
                    Height = 30
                    Anchors = [akTop, akRight]
                    Style = csDropDown
                    Hint = 'Equaliser preset: pick a saved one to load it at once, or type a name for a new one and use the Save icon.'
                    OnSelect = cboMixEqPresetSelect
                    TabOrder = 18
                  end
                  object ibMixEqPreset: TGLIconBar
                    Left = 526
                    Top = 11
                    Width = 56
                    Height = 24
                    Anchors = [akTop, akRight]
                    ShowHint = True
                    Transparent = True
                    Buttons = 'load;save'
                    Hints = 'Load the preset named in the box;Save the current band settings under the name in the box'
                    CellWidth = 28
                    OnButtonClick = MixEqPresetClick
                  end
                  object sbMixEq01: TGLEqSlider
                    Left = 12
                    Top = 46
                    Width = 37
                    Height = 140
                    Anchors = [akLeft, akTop, akBottom]
                    Tag = 0
                    Min = -12.000000000000000000
                    Max = 12.000000000000000000
                    DefaultPosition = 0.000000000000000000
                    Step = 0.500000000000000000
                    Vertical = True
                    Hint = 'Gain of the 25 Hz band on the Master output. Double-click to reset it to 0 dB.'
                    TabOrder = 0
                    OnChange = MixEqSliderChange
                  end
                  object lblMixEq01: TGLLabel
                    Left = 12
                    Top = 190
                    Width = 37
                    Height = 15
                    Anchors = [akLeft, akBottom]
                    Alignment = taCenter
                    AutoSize = False
                    Caption = '25'
                    Transparent = True
                  end
                  object sbMixEq02: TGLEqSlider
                    Left = 49
                    Top = 46
                    Width = 37
                    Height = 140
                    Anchors = [akLeft, akTop, akBottom]
                    Tag = 1
                    Min = -12.000000000000000000
                    Max = 12.000000000000000000
                    DefaultPosition = 0.000000000000000000
                    Step = 0.500000000000000000
                    Vertical = True
                    Hint = 'Gain of the 38 Hz band on the Master output. Double-click to reset it to 0 dB.'
                    TabOrder = 1
                    OnChange = MixEqSliderChange
                  end
                  object lblMixEq02: TGLLabel
                    Left = 49
                    Top = 190
                    Width = 37
                    Height = 15
                    Anchors = [akLeft, akBottom]
                    Alignment = taCenter
                    AutoSize = False
                    Caption = '38'
                    Transparent = True
                  end
                  object sbMixEq03: TGLEqSlider
                    Left = 86
                    Top = 46
                    Width = 37
                    Height = 140
                    Anchors = [akLeft, akTop, akBottom]
                    Tag = 2
                    Min = -12.000000000000000000
                    Max = 12.000000000000000000
                    DefaultPosition = 0.000000000000000000
                    Step = 0.500000000000000000
                    Vertical = True
                    Hint = 'Gain of the 59 Hz band on the Master output. Double-click to reset it to 0 dB.'
                    TabOrder = 2
                    OnChange = MixEqSliderChange
                  end
                  object lblMixEq03: TGLLabel
                    Left = 86
                    Top = 190
                    Width = 37
                    Height = 15
                    Anchors = [akLeft, akBottom]
                    Alignment = taCenter
                    AutoSize = False
                    Caption = '59'
                    Transparent = True
                  end
                  object sbMixEq04: TGLEqSlider
                    Left = 123
                    Top = 46
                    Width = 37
                    Height = 140
                    Anchors = [akLeft, akTop, akBottom]
                    Tag = 3
                    Min = -12.000000000000000000
                    Max = 12.000000000000000000
                    DefaultPosition = 0.000000000000000000
                    Step = 0.500000000000000000
                    Vertical = True
                    Hint = 'Gain of the 91 Hz band on the Master output. Double-click to reset it to 0 dB.'
                    TabOrder = 3
                    OnChange = MixEqSliderChange
                  end
                  object lblMixEq04: TGLLabel
                    Left = 123
                    Top = 190
                    Width = 37
                    Height = 15
                    Anchors = [akLeft, akBottom]
                    Alignment = taCenter
                    AutoSize = False
                    Caption = '91'
                    Transparent = True
                  end
                  object sbMixEq05: TGLEqSlider
                    Left = 160
                    Top = 46
                    Width = 37
                    Height = 140
                    Anchors = [akLeft, akTop, akBottom]
                    Tag = 4
                    Min = -12.000000000000000000
                    Max = 12.000000000000000000
                    DefaultPosition = 0.000000000000000000
                    Step = 0.500000000000000000
                    Vertical = True
                    Hint = 'Gain of the 140 Hz band on the Master output. Double-click to reset it to 0 dB.'
                    TabOrder = 4
                    OnChange = MixEqSliderChange
                  end
                  object lblMixEq05: TGLLabel
                    Left = 160
                    Top = 190
                    Width = 37
                    Height = 15
                    Anchors = [akLeft, akBottom]
                    Alignment = taCenter
                    AutoSize = False
                    Caption = '140'
                    Transparent = True
                  end
                  object sbMixEq06: TGLEqSlider
                    Left = 197
                    Top = 46
                    Width = 37
                    Height = 140
                    Anchors = [akLeft, akTop, akBottom]
                    Tag = 5
                    Min = -12.000000000000000000
                    Max = 12.000000000000000000
                    DefaultPosition = 0.000000000000000000
                    Step = 0.500000000000000000
                    Vertical = True
                    Hint = 'Gain of the 215 Hz band on the Master output. Double-click to reset it to 0 dB.'
                    TabOrder = 5
                    OnChange = MixEqSliderChange
                  end
                  object lblMixEq06: TGLLabel
                    Left = 197
                    Top = 190
                    Width = 37
                    Height = 15
                    Anchors = [akLeft, akBottom]
                    Alignment = taCenter
                    AutoSize = False
                    Caption = '215'
                    Transparent = True
                  end
                  object sbMixEq07: TGLEqSlider
                    Left = 234
                    Top = 46
                    Width = 37
                    Height = 140
                    Anchors = [akLeft, akTop, akBottom]
                    Tag = 6
                    Min = -12.000000000000000000
                    Max = 12.000000000000000000
                    DefaultPosition = 0.000000000000000000
                    Step = 0.500000000000000000
                    Vertical = True
                    Hint = 'Gain of the 330 Hz band on the Master output. Double-click to reset it to 0 dB.'
                    TabOrder = 6
                    OnChange = MixEqSliderChange
                  end
                  object lblMixEq07: TGLLabel
                    Left = 234
                    Top = 190
                    Width = 37
                    Height = 15
                    Anchors = [akLeft, akBottom]
                    Alignment = taCenter
                    AutoSize = False
                    Caption = '330'
                    Transparent = True
                  end
                  object sbMixEq08: TGLEqSlider
                    Left = 271
                    Top = 46
                    Width = 37
                    Height = 140
                    Anchors = [akLeft, akTop, akBottom]
                    Tag = 7
                    Min = -12.000000000000000000
                    Max = 12.000000000000000000
                    DefaultPosition = 0.000000000000000000
                    Step = 0.500000000000000000
                    Vertical = True
                    Hint = 'Gain of the 510 Hz band on the Master output. Double-click to reset it to 0 dB.'
                    TabOrder = 7
                    OnChange = MixEqSliderChange
                  end
                  object lblMixEq08: TGLLabel
                    Left = 271
                    Top = 190
                    Width = 37
                    Height = 15
                    Anchors = [akLeft, akBottom]
                    Alignment = taCenter
                    AutoSize = False
                    Caption = '510'
                    Transparent = True
                  end
                  object sbMixEq09: TGLEqSlider
                    Left = 308
                    Top = 46
                    Width = 37
                    Height = 140
                    Anchors = [akLeft, akTop, akBottom]
                    Tag = 8
                    Min = -12.000000000000000000
                    Max = 12.000000000000000000
                    DefaultPosition = 0.000000000000000000
                    Step = 0.500000000000000000
                    Vertical = True
                    Hint = 'Gain of the 780 Hz band on the Master output. Double-click to reset it to 0 dB.'
                    TabOrder = 8
                    OnChange = MixEqSliderChange
                  end
                  object lblMixEq09: TGLLabel
                    Left = 308
                    Top = 190
                    Width = 37
                    Height = 15
                    Anchors = [akLeft, akBottom]
                    Alignment = taCenter
                    AutoSize = False
                    Caption = '780'
                    Transparent = True
                  end
                  object sbMixEq10: TGLEqSlider
                    Left = 345
                    Top = 46
                    Width = 37
                    Height = 140
                    Anchors = [akLeft, akTop, akBottom]
                    Tag = 9
                    Min = -12.000000000000000000
                    Max = 12.000000000000000000
                    DefaultPosition = 0.000000000000000000
                    Step = 0.500000000000000000
                    Vertical = True
                    Hint = 'Gain of the 1.2k Hz band on the Master output. Double-click to reset it to 0 dB.'
                    TabOrder = 9
                    OnChange = MixEqSliderChange
                  end
                  object lblMixEq10: TGLLabel
                    Left = 345
                    Top = 190
                    Width = 37
                    Height = 15
                    Anchors = [akLeft, akBottom]
                    Alignment = taCenter
                    AutoSize = False
                    Caption = '1.2k'
                    Transparent = True
                  end
                  object sbMixEq11: TGLEqSlider
                    Left = 382
                    Top = 46
                    Width = 37
                    Height = 140
                    Anchors = [akLeft, akTop, akBottom]
                    Tag = 10
                    Min = -12.000000000000000000
                    Max = 12.000000000000000000
                    DefaultPosition = 0.000000000000000000
                    Step = 0.500000000000000000
                    Vertical = True
                    Hint = 'Gain of the 1.9k Hz band on the Master output. Double-click to reset it to 0 dB.'
                    TabOrder = 10
                    OnChange = MixEqSliderChange
                  end
                  object lblMixEq11: TGLLabel
                    Left = 382
                    Top = 190
                    Width = 37
                    Height = 15
                    Anchors = [akLeft, akBottom]
                    Alignment = taCenter
                    AutoSize = False
                    Caption = '1.9k'
                    Transparent = True
                  end
                  object sbMixEq12: TGLEqSlider
                    Left = 419
                    Top = 46
                    Width = 37
                    Height = 140
                    Anchors = [akLeft, akTop, akBottom]
                    Tag = 11
                    Min = -12.000000000000000000
                    Max = 12.000000000000000000
                    DefaultPosition = 0.000000000000000000
                    Step = 0.500000000000000000
                    Vertical = True
                    Hint = 'Gain of the 2.8k Hz band on the Master output. Double-click to reset it to 0 dB.'
                    TabOrder = 11
                    OnChange = MixEqSliderChange
                  end
                  object lblMixEq12: TGLLabel
                    Left = 419
                    Top = 190
                    Width = 37
                    Height = 15
                    Anchors = [akLeft, akBottom]
                    Alignment = taCenter
                    AutoSize = False
                    Caption = '2.8k'
                    Transparent = True
                  end
                  object sbMixEq13: TGLEqSlider
                    Left = 456
                    Top = 46
                    Width = 37
                    Height = 140
                    Anchors = [akLeft, akTop, akBottom]
                    Tag = 12
                    Min = -12.000000000000000000
                    Max = 12.000000000000000000
                    DefaultPosition = 0.000000000000000000
                    Step = 0.500000000000000000
                    Vertical = True
                    Hint = 'Gain of the 4.4k Hz band on the Master output. Double-click to reset it to 0 dB.'
                    TabOrder = 12
                    OnChange = MixEqSliderChange
                  end
                  object lblMixEq13: TGLLabel
                    Left = 456
                    Top = 190
                    Width = 37
                    Height = 15
                    Anchors = [akLeft, akBottom]
                    Alignment = taCenter
                    AutoSize = False
                    Caption = '4.4k'
                    Transparent = True
                  end
                  object sbMixEq14: TGLEqSlider
                    Left = 493
                    Top = 46
                    Width = 37
                    Height = 140
                    Anchors = [akLeft, akTop, akBottom]
                    Tag = 13
                    Min = -12.000000000000000000
                    Max = 12.000000000000000000
                    DefaultPosition = 0.000000000000000000
                    Step = 0.500000000000000000
                    Vertical = True
                    Hint = 'Gain of the 6.7k Hz band on the Master output. Double-click to reset it to 0 dB.'
                    TabOrder = 13
                    OnChange = MixEqSliderChange
                  end
                  object lblMixEq14: TGLLabel
                    Left = 493
                    Top = 190
                    Width = 37
                    Height = 15
                    Anchors = [akLeft, akBottom]
                    Alignment = taCenter
                    AutoSize = False
                    Caption = '6.7k'
                    Transparent = True
                  end
                  object sbMixEq15: TGLEqSlider
                    Left = 530
                    Top = 46
                    Width = 37
                    Height = 140
                    Anchors = [akLeft, akTop, akBottom]
                    Tag = 14
                    Min = -12.000000000000000000
                    Max = 12.000000000000000000
                    DefaultPosition = 0.000000000000000000
                    Step = 0.500000000000000000
                    Vertical = True
                    Hint = 'Gain of the 10k Hz band on the Master output. Double-click to reset it to 0 dB.'
                    TabOrder = 14
                    OnChange = MixEqSliderChange
                  end
                  object lblMixEq15: TGLLabel
                    Left = 530
                    Top = 190
                    Width = 37
                    Height = 15
                    Anchors = [akLeft, akBottom]
                    Alignment = taCenter
                    AutoSize = False
                    Caption = '10k'
                    Transparent = True
                  end
                  object sbMixEq16: TGLEqSlider
                    Left = 567
                    Top = 46
                    Width = 37
                    Height = 140
                    Anchors = [akLeft, akTop, akBottom]
                    Tag = 15
                    Min = -12.000000000000000000
                    Max = 12.000000000000000000
                    DefaultPosition = 0.000000000000000000
                    Step = 0.500000000000000000
                    Vertical = True
                    Hint = 'Gain of the 16k Hz band on the Master output. Double-click to reset it to 0 dB.'
                    TabOrder = 15
                    OnChange = MixEqSliderChange
                  end
                  object lblMixEq16: TGLLabel
                    Left = 567
                    Top = 190
                    Width = 37
                    Height = 15
                    Anchors = [akLeft, akBottom]
                    Alignment = taCenter
                    AutoSize = False
                    Caption = '16k'
                    Transparent = True
                  end
                  object chkMixEqOn: TGLCheck
                    Left = 12
                    Top = 213
                    Width = 120
                    Height = 20
                    Anchors = [akLeft, akBottom]
                    Caption = 'EQ on'
                    Checked = True
                    Hint = 'Switch the Master graphic equaliser on or off.'
                    TabOrder = 16
                    OnChange = MixEqOnChange
                  end
                  object btnMixEqFlat: TGLButton
                    Left = 140
                    Top = 210
                    Width = 80
                    Height = 25
                    Anchors = [akLeft, akBottom]
                    Caption = 'Flat'
                    Hint = 'Set every band back to 0 dB.'
                    TabOrder = 17
                    OnClick = MixEqFlatClick
                  end
                end
  
              end
            end
            object tabMIDI: TGLPage
              Caption = 'MIDI'
              ImageIndex = 15
              object pnlMidiTop: TGLPanel
                Left = 0
                Top = 0
                Width = 952
                Height = 76
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                object lblMidiClip: TGLLabel
                  Transparent = True
                  Left = 10
                  Top = 13
                  Width = 22
                  Height = 15
                  Caption = 'Clip'
                end
                object cboMidiClip: TGLCombo
                  Left = 46
                  Top = 8
                  Width = 200
                  Height = 24
                  TabOrder = 0
                  OnChange = cboMidiClipChange
                end
                object lblMidiGrid: TGLLabel
                  Transparent = True
                  Left = 264
                  Top = 13
                  Width = 22
                  Height = 15
                  Caption = 'Grid'
                end
                object cboMidiGrid: TGLCombo
                  Left = 294
                  Top = 8
                  Width = 84
                  Height = 24
                  TabOrder = 1
                end
                object bvlMidiSep1: TGLBevel
                  Left = 394
                  Top = 8
                  Width = 2
                  Height = 24
                  Shape = bsLeftLine
                end
                object lblMidiNote: TGLLabel
                  Transparent = True
                  Left = 410
                  Top = 13
                  Width = 62
                  Height = 15
                  Caption = 'Add note'
                end
                object edtMidiNote: TGLEdit
                  Left = 478
                  Top = 8
                  Width = 48
                  Height = 24
                  Hint = 'Note number (60 = middle C)'
                  ParentShowHint = False
                  ShowHint = True
                  TabOrder = 2
                  Text = '60'
                end
                object edtMidiStart: TGLEdit
                  Left = 530
                  Top = 8
                  Width = 60
                  Height = 24
                  Hint = 'Start, in ticks'
                  ParentShowHint = False
                  ShowHint = True
                  TabOrder = 3
                  Text = '0'
                end
                object edtMidiLen: TGLEdit
                  Left = 594
                  Top = 8
                  Width = 60
                  Height = 24
                  Hint = 'Length, in ticks'
                  ParentShowHint = False
                  ShowHint = True
                  TabOrder = 4
                  Text = '480'
                end
                object edtMidiVel: TGLEdit
                  Left = 658
                  Top = 8
                  Width = 48
                  Height = 24
                  Hint = 'Velocity (1 to 127)'
                  ParentShowHint = False
                  ShowHint = True
                  TabOrder = 5
                  Text = '100'
                end
                object lblMidiTrack: TGLLabel
                  Transparent = True
                  Left = 722
                  Top = 13
                  Width = 33
                  Height = 15
                  Caption = 'Track'
                end
                object cboMidiTrack: TGLCombo
                  Left = 760
                  Top = 8
                  Width = 184
                  Height = 24
                  TabOrder = 11
                  OnChange = cboMidiTrackChange
                end
                object lblMidiScale: TGLLabel
                  Transparent = True
                  Left = 10
                  Top = 46
                  Width = 33
                  Height = 15
                  Caption = 'Scale'
                end
                object cboMidiScaleRoot: TGLCombo
                  Left = 46
                  Top = 41
                  Width = 70
                  Height = 24
                  TabOrder = 6
                  OnChange = cboMidiScaleChange
                end
                object cboMidiScaleType: TGLCombo
                  Left = 122
                  Top = 41
                  Width = 150
                  Height = 24
                  TabOrder = 7
                  OnChange = cboMidiScaleChange
                end
                object chkMidiScaleHighlight: TGLCheck
                  Left = 288
                  Top = 44
                  Width = 130
                  Height = 17
                  Caption = 'Highlight scale'
                  TabOrder = 8
                  OnClick = chkMidiScaleHighlightClick
                end
                object bvlMidiSep2: TGLBevel
                  Left = 430
                  Top = 41
                  Width = 2
                  Height = 24
                  Shape = bsLeftLine
                end
                object chkMidiChords: TGLCheck
                  Left = 446
                  Top = 44
                  Width = 100
                  Height = 17
                  Hint = 'Show the chord symbols of the Chords lane over the roll'
                  Caption = 'Chord lane'
                  Checked = True
                  ParentShowHint = False
                  ShowHint = True
                  TabOrder = 9
                  OnClick = chkMidiChordsClick
                end
                object btnMidiDetectChords: TGLButton
                  Left = 556
                  Top = 41
                  Width = 130
                  Height = 24
                  Hint = 'Name the chord of every bar from the notes and write them into the Chords lane'
                  Caption = 'Detect chords'
                  ParentShowHint = False
                  ShowHint = True
                  TabOrder = 10
                  OnClick = btnMidiDetectChordsClick
                end
              end
              object sbMidiH: TGLScrollBar
                Left = 0
                Top = 350
                Width = 952
                Height = 16
                Align = alBottom
                Kind = sbHorizontal
                PageSize = 0
                TabOrder = 2
                OnChange = sbMidiHChange
              end
              object sbMidiV: TGLScrollBar
                Left = 936
                Top = 76
                Width = 16
                Height = 274
                Align = alRight
                Hint = 'Scrolls the piano roll up and down. Ctrl + mouse wheel does the same.'
                Kind = sbVertical
                PageSize = 0
                TabOrder = 3
                OnChange = sbMidiVChange
              end
              object pbPianoRoll: TGLView
                Left = 0
                Top = 76
                Width = 952
                Height = 290
                Align = alClient
                PopupMenu = pmPianoRoll
                OnMouseDown = pbPianoRollMouseDown
                OnMouseMove = pbPianoRollMouseMove
                OnMouseUp = pbPianoRollMouseUp
                OnMouseWheel = pbPianoRollMouseWheel
                OnPaint = pbPianoRollPaint
              end
            end
            object tabScore: TGLPage
              Caption = 'Score'
              object sbScoreParts: TGLScrollBox
                Left = 0
                Top = 0
                Width = 250
                Height = 400
                Align = alLeft
                TabOrder = 0
                ContentPadding = 0
              OnResize = sbScorePartsResize
                object pnlScoreParts: TGLPanel
                  Left = 0
                  Top = 0
                  Width = 236
                  Height = 420
                  BevelOuter = bvNone
                  TabOrder = 0
                  object pnlScorePartsHead: TGLPanel
                    Left = 0
                    Top = 0
                    Width = 100
                    Height = 92
                    Align = alTop
                    BevelOuter = bvNone
                    TabOrder = 9
                    object lblScoreParts: TGLLabel
                      Transparent = True
                      Left = 12
                      Top = 10
                      Width = 36
                      Height = 15
                      Caption = 'PARTS'
                      Font.Style = [fsBold]
                      ParentFont = False
                    end
                    object lblScoreCount: TGLLabel
                      Transparent = True
                      Left = 170
                      Top = 10
                      Width = 56
                      Height = 15
                      Caption = '0 of 0'
                    end
                    object btnScoreSel: TGLButton
                      Left = 10
                      Top = 32
                      Width = 106
                      Height = 24
                      Hint = 'Show only the parts selected in the list'
                      Caption = 'Selection'
                      ParentShowHint = False
                      ShowHint = True
                      TabOrder = 0
                      Toggle = True
                      Down = True
                      OnChange = ScoreOptionChange
                    end
                    object btnScoreFull: TGLButton
                      Left = 120
                      Top = 32
                      Width = 106
                      Height = 24
                      Hint = 'Show every MIDI part as one full score'
                      Caption = 'Full score'
                      ParentShowHint = False
                      ShowHint = True
                      TabOrder = 1
                      Toggle = True
                      OnChange = ScoreOptionChange
                    end
                    object btnScoreChords: TGLButton
                      Left = 10
                      Top = 62
                      Width = 106
                      Height = 24
                      Hint = 'Print the Chords lane symbols above the staves'
                      Caption = 'Chord symbols'
                      ParentShowHint = False
                      ShowHint = True
                      TabOrder = 2
                      Toggle = True
                      Down = True
                      OnChange = ScoreOptionChange
                    end
                    object btnScoreTab: TGLButton
                      Left = 120
                      Top = 62
                      Width = 106
                      Height = 24
                      Hint = 'Show the notes as guitar tablature (six strings, fret numbers, standard tuning) instead of staff notation'
                      Caption = 'Guitar tab'
                      ParentShowHint = False
                      ShowHint = True
                      TabOrder = 6
                      Toggle = True
                      OnChange = ScoreOptionChange
                    end
                  end
                  object pnlScorePartsFoot: TGLPanel
                    Left = 0
                    Top = 0
                    Width = 100
                    Height = 34
                    Align = alBottom
                    BevelOuter = bvNone
                    TabOrder = 9
                    object btnScoreAll: TGLButton
                      Left = 10
                      Top = 5
                      Width = 106
                      Height = 24
                      Hint = 'Select every part'
                      Caption = 'All tracks'
                      ParentShowHint = False
                      ShowHint = True
                      TabOrder = 4
                      OnClick = btnScoreAllClick
                    end
                    object btnScoreNone: TGLButton
                      Left = 120
                      Top = 5
                      Width = 106
                      Height = 24
                      Hint = 'Clear the selection'
                      Caption = 'Clear'
                      ParentShowHint = False
                      ShowHint = True
                      TabOrder = 5
                      OnClick = btnScoreNoneClick
                    end
                  end
                  object pnlScoreTrk: TGLPanel
                    Left = 0
                    Top = 0
                    Width = 100
                    Height = 192
                    Align = alBottom
                    BevelOuter = bvNone
                    TabOrder = 10
                    object lblScoreTrk: TGLLabel
                      Transparent = True
                      Left = 12
                      Top = 9
                      Width = 56
                      Height = 15
                      Caption = 'TRACKER'
                      Font.Style = [fsBold]
                      ParentFont = False
                    end
                    object tsScoreTrkBy: TGLTabStrip
                      CurvedTabs = True
                      TabColor = 7214150
                      Left = 10
                      Top = 34
                      Width = 216
                      Height = 28
                      Tabs = 'Channels;Instruments'
                      Hints = 'Pick the tracker channels to show;Pick the tracker instruments to show'
                      OnChange = ScoreTrkByChange
                    end
                    object lstScoreTrk: TGLList
                      Left = 10
                      Top = 66
                      Width = 216
                      Height = 90
                      Hint = 'Only the notes on the selected channels / instruments are shown (Ctrl / Shift for several)'
                      MultiSelect = True
                      ParentShowHint = False
                      ShowHint = True
                      TabOrder = 1
                      OnClick = ScoreTrkListClick
                    end
                    object btnScoreTrkAll: TGLButton
                      Left = 10
                      Top = 162
                      Width = 106
                      Height = 24
                      Hint = 'Show every channel / instrument'
                      Caption = 'Show all'
                      ParentShowHint = False
                      ShowHint = True
                      TabOrder = 2
                      OnClick = btnScoreTrkAllClick
                    end
                    object btnScoreTrkNone: TGLButton
                      Left = 120
                      Top = 162
                      Width = 106
                      Height = 24
                      Hint = 'Hide every channel / instrument'
                      Caption = 'Hide all'
                      ParentShowHint = False
                      ShowHint = True
                      TabOrder = 3
                      OnClick = btnScoreTrkNoneClick
                    end
                  end
                  object lstScoreParts: TGLList
                    Align = alClient
                    AlignWithMargins = True
                    Margins.Left = 10
                    Margins.Top = 4
                    Margins.Right = 10
                    Margins.Bottom = 4
                    Left = 10
                    Top = 96
                    Width = 216
                    Height = 270
                    Hint = 'The MIDI parts of the Timeline: select the ones to show (Ctrl / Shift for several)'
                    MultiSelect = True
                    ParentShowHint = False
                    ShowHint = True
                    TabOrder = 3
                    OnClick = ScoreOptionChange
                  end
                end
              end
              object pnlScoreTop: TGLPanel
                Left = 236
                Top = 0
                Width = 716
                Height = 38
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 1
                object ibScoreTools: TGLIconBar
                  Left = 8
                  Top = 5
                  Width = 224
                  Height = 28
                  ShowHint = True
                  Buttons = 'open;save;trash;zoomout;zoomin;play;stop'
                  Hints = 'Load a tracker module onto the score;Save the score as laid out - staff notation or guitar tab - to a PDF file;Delete the selected score parts from the project (asks first);Smaller notation;Larger notation;Play the Timeline from the playhead: a thick line scrolls across the score at the Timeline tempo;Stop playback'
                  OnButtonClick = ibScoreToolsClick
                end
                object tsScoreClef: TGLTabStrip
                  CurvedTabs = True
                  TabColor = 7214150
                  Left = 244
                  Top = 5
                  Width = 280
                  Height = 28
                  Tabs = 'AUTO;TREBLE;BASS;GRAND'
                  Hints = 'Choose the staff from the notes;Treble clef only;Bass clef only;Grand staff: treble above bass'
                  OnChange = ScoreOptionChange
                end
                object lblScoreQuant: TGLLabel
                  Transparent = True
                  Left = 536
                  Top = 11
                  Width = 52
                  Height = 15
                  Caption = 'Quantize'
                end
                object cboScoreQuant: TGLCombo
                  Left = 594
                  Top = 7
                  Width = 80
                  Height = 24
                  Hint = 'The shortest note value the notation is rounded to'
                  ItemIndex = 2
                  ParentShowHint = False
                  ShowHint = True
                  TabOrder = 0
                  OnChange = ScoreOptionChange
                  Items.Strings = (
                    '1/4'
                    '1/8'
                    '1/16'
                    '1/32')
                end
                object lblScoreZoom: TGLLabel
                  Transparent = True
                  Left = 686
                  Top = 11
                  Width = 40
                  Height = 15
                  Caption = '100%'
                end
              end
              object sbScore: TGLScrollBar
                Left = 934
                Top = 38
                Width = 18
                Height = 362
                Align = alRight
                Kind = sbVertical
                PageSize = 0
                TabOrder = 3
                OnChange = ScoreOptionChange
              end
              object sbScoreH: TGLScrollBar
                Left = 236
                Top = 382
                Width = 698
                Height = 18
                Align = alBottom
                Kind = sbHorizontal
                PageSize = 0
                TabOrder = 4
                OnChange = ScoreOptionChange
              end
              object pbScore: TGLView
                Left = 236
                Top = 38
                Width = 698
                Height = 362
                Align = alClient
                OnMouseDown = pbScoreMouseDown
                OnMouseWheel = pbScoreMouseWheel
                OnPaint = pbScorePaint
              end
            end
            object tabInst: TGLPage
              Caption = 'Instrument'
              object lblDrumTitle: TGLLabel
                Transparent = True
                Left = 18
                Top = 14
                Width = 110
                Height = 20
                Caption = 'Drum Machine'
                Font.Height = -16
                Font.Style = [fsBold]
                ParentFont = False
              end
              object lblDrumHint: TGLLabel
                Transparent = True
                Left = 160
                Top = 18
                Width = 420
                Height = 15
                Caption = 'Every MIDI note 0 to 127 has a pad - scroll the range, click a pad to play it, drop a WAV file on it or press its + to load one'
              end
              object pbDrumMap: TGLView
                Left = 18
                Top = 48
                Width = 44
                Height = 300
                Cursor = crHandPoint
                OnMouseDown = pbDrumMapMouseDown
                OnMouseMove = pbDrumMapMouseMove
                OnMouseUp = pbDrumMapMouseUp
                OnPaint = pbDrumMapPaint
              end
              object pbDrumPads: TGLView
                Left = 70
                Top = 48
                Width = 440
                Height = 300
                Cursor = crHandPoint
                OnDropFiles = pbDrumPadsDropFiles
                OnDblClick = pbDrumPadsDblClick
                OnMouseDown = pbDrumPadsMouseDown
                OnMouseUp = pbDrumPadsMouseUp
                OnMouseWheel = pbDrumPadsMouseWheel
                OnPaint = pbDrumPadsPaint
              end
              object sbDrumRange: TGLScrollBar
                Left = 514
                Top = 48
                Width = 18
                Height = 300
                Kind = sbVertical
                Max = 31
                PageSize = 4
                Position = 19
                LargeChange = 4
                TabOrder = 1
                OnChange = sbDrumRangeChange
              end
              object sbDrumPanels: TGLScrollBox
                Left = 544
                Top = 48
                Width = 400
                Height = 340
                TabOrder = 0
                object lblDrumEmpty: TGLLabel
                  Transparent = True
                  Left = 14
                  Top = 14
                  Width = 360
                  Height = 60
                  WordWrap = True
                  Caption = 'Load a WAV file onto a pad (double-click it, press its + or drop a file on it) and the instrument gets its own panel here, with a graph of its sound.'
                end
              end
            end
            object tabPattern: TGLPage
              Caption = 'Pattern'
              object pnlPatTop: TGLPanel
                Left = 0
                Top = 0
                Width = 952
                Height = 108
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                object cboPatSel: TGLCombo
                  Left = 10
                  Top = 8
                  Width = 210
                  Height = 24
                  Hint = 'The rhythm patterns of this project'
                  ParentShowHint = False
                  ShowHint = True
                  TabOrder = 0
                  OnChange = cboPatSelChange
                end
                object ibPatFile: TGLIconBar
                  Left = 228
                  Top = 6
                  Width = 184
                  Height = 28
                  ShowHint = True
                  Buttons = 'add;clone;trash;save;saveas;load'
                  Hints = 'New pattern (a row for every loaded drum pad);Clone this pattern;Delete this pattern;Save this pattern, with its instruments, as a preset file;Save this pattern as a preset file under a name you choose;Load a pattern preset into this project'
                  OnButtonClick = ibPatFileClick
                end
                object ibPatPlay: TGLIconBar
                  Left = 870
                  Top = 6
                  Width = 34
                  Height = 28
                  Anchors = [akTop, akRight]
                  ShowHint = True
                  Buttons = 'play'
                  Hints = 'Play the pattern in a loop through the drum machine'
                  OnButtonClick = ibPatPlayClick
                end
                object ibPatPlace: TGLIconBar
                  Left = 908
                  Top = 6
                  Width = 34
                  Height = 28
                  Anchors = [akTop, akRight]
                  ShowHint = True
                  Buttons = 'place'
                  Hints = 'Put the pattern on the Timeline at the playhead as a clip; edit the pattern later and every copy follows'
                  OnButtonClick = ibPatPlaceClick
                end
                object lblPatName: TGLLabel
                  Transparent = True
                  Left = 10
                  Top = 47
                  Width = 40
                  Height = 15
                  Caption = 'Name'
                end
                object edtPatName: TGLEdit
                  Left = 56
                  Top = 42
                  Width = 170
                  Height = 24
                  TabOrder = 9
                  TextHint = 'Pattern name'
                  OnChange = edtPatNameChange
                end
                object lblPatLen: TGLLabel
                  Transparent = True
                  Left = 240
                  Top = 47
                  Width = 46
                  Height = 15
                  Caption = 'Length'
                end
                object ibPatLen: TGLIconBar
                  Left = 292
                  Top = 40
                  Width = 64
                  Height = 28
                  ShowHint = True
                  Buttons = 'minus;add'
                  Hints = 'One beat shorter;One beat longer'
                  OnButtonClick = ibPatLenClick
                end
                object lblPatLenVal: TGLLabel
                  Transparent = True
                  Left = 364
                  Top = 47
                  Width = 28
                  Height = 15
                  Caption = '32'
                end
                object lblPatBars: TGLLabel
                  Transparent = True
                  Left = 396
                  Top = 47
                  Width = 110
                  Height = 15
                  Caption = 'rows / 2.00 bars'
                end
                object tsPatRes: TGLTabStrip
                  Left = 512
                  Top = 40
                  Width = 170
                  Height = 28
                  Tabs = '1/8;1/16;1/32'
                  Hints = 'Eighth-note steps;Sixteenth-note steps;Thirty-second-note steps'
                  OnChange = tsPatResChange
                end
                object cboPatAdd: TGLCombo
                  Left = 696
                  Top = 42
                  Width = 150
                  Height = 24
                  Hint = 'A loaded drum pad to add as a row'
                  ParentShowHint = False
                  ShowHint = True
                  TabOrder = 12
                end
                object ibPatRow: TGLIconBar
                  Left = 852
                  Top = 40
                  Width = 64
                  Height = 28
                  ShowHint = True
                  Buttons = 'addrow;delrow'
                  Hints = 'Add the chosen pad (or the pad selected on the Instrument page) as an instrument row;Remove the selected instrument row'
                  OnButtonClick = ibPatRowClick
                end
                object ibPatTools: TGLIconBar
                  Left = 10
                  Top = 74
                  Width = 184
                  Height = 28
                  ShowHint = True
                  Buttons = 'fill;euclid;left;right;random;clear'
                  Hints = 'Fill: hit every n-th step on the selected row (every row if none is selected);Euclid: spread a number of hits evenly over the selected row;Rotate the steps one to the left;Rotate the steps one to the right;Random: scatter hits over the selected row (every row if none is selected);Clear: remove every hit from the selected row (every row if none is selected)'
                  OnButtonClick = ibPatToolsClick
                end
                object lblPatInfo: TGLLabel
                  Transparent = True
                  Left = 206
                  Top = 81
                  Width = 734
                  Height = 15
                  Caption = ''
                end
              end
              object sbPatV: TGLScrollBar
                Left = 934
                Top = 108
                Width = 18
                Height = 176
                Align = alRight
                Kind = sbVertical
                PageSize = 0
                TabOrder = 1
                OnChange = sbPatChange
              end
              object sbPatH: TGLScrollBar
                Left = 0
                Top = 284
                Width = 934
                Height = 16
                Align = alBottom
                Kind = sbHorizontal
                PageSize = 0
                TabOrder = 2
                OnChange = sbPatChange
              end
              object pbPattern: TGLView
                Left = 0
                Top = 108
                Width = 934
                Height = 176
                Align = alClient
                Cursor = crHandPoint
                OnMouseDown = pbPatternMouseDown
                OnMouseMove = pbPatternMouseMove
                OnMouseUp = pbPatternMouseUp
                OnMouseWheel = pbPatternMouseWheel
                OnPaint = pbPatternPaint
              end
            end
            object tabTracker: TGLPage
              Caption = 'Tracker'
              ImageIndex = 12
              DoubleBuffered = True
              ParentDoubleBuffered = False
              object pgcTrk: TGLPageControl
                Left = 0
                Top = 0
                Width = 952
                Height = 556
                ActivePage = tsTrkModule
                Align = alClient
                TabOrder = 0
              object tsTrkModule: TGLPage
                Caption = 'Module'
              object pnlTrkTop: TGLPanel
                Left = 0
                Top = 0
                Width = 952
                Height = 42
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                object lblTrkPattern: TGLLabel
                  Transparent = True
                  Left = 10
                  Top = 14
                  Width = 41
                  Height = 15
                  Caption = 'Pattern'
                end
                object cboTrkPattern: TGLCombo
                  Left = 62
                  Top = 9
                  Width = 190
                  Height = 24
                  TabOrder = 0
                  OnChange = cboTrkPatternChange
                end
                object lblTrkSpeed: TGLLabel
                  Transparent = True
                  Left = 272
                  Top = 14
                  Width = 34
                  Height = 15
                  Caption = 'Speed'
                end
                object edtTrkSpeed: TGLEdit
                  Left = 312
                  Top = 9
                  Width = 40
                  Height = 24
                  TabOrder = 1
                  Text = '6'
                end
                object lblTrkBPM: TGLLabel
                  Transparent = True
                  Left = 368
                  Top = 14
                  Width = 27
                  Height = 15
                  Caption = 'BPM'
                end
                object edtTrkBPM: TGLEdit
                  Left = 400
                  Top = 9
                  Width = 48
                  Height = 24
                  TabOrder = 2
                  Text = '125'
                end
                object lblTrkInstrPick: TGLLabel
                  Transparent = True
                  Left = 468
                  Top = 14
                  Width = 60
                  Height = 15
                  Caption = 'Instrument'
                end
                object cboTrkInstr: TGLCombo
                  Left = 534
                  Top = 9
                  Width = 240
                  Height = 24
                  Hint = 'The instrument notes are entered with; lists every instrument loaded in this module'
                  TabOrder = 3
                  OnChange = cboTrkInstrPickChange
                end
              end
              object pnlTrkSupport: TGLPanel
                Left = 0
                Top = 500
                Width = 952
                Height = 32
                Align = alBottom
                BevelOuter = bvNone
                TabOrder = 3
                object lblTrkSupport: TGLLabel
                  Left = 0
                  Top = 0
                  Width = 740
                  Height = 32
                  Align = alClient
                  AutoSize = False
                  Caption = 'Dedicated tracker-module editing: visit and support ModPlug.'
                  Layout = tlCenter
                  WordWrap = True
                end
                object btnTrkSupport: TGLButton
                  Left = 740
                  Top = 0
                  Width = 212
                  Height = 32
                  Align = alRight
                  Caption = 'Visit www.modplug.com'
                  TabOrder = 0
                  OnClick = btnTrkSupportClick
                end
              end
              object pnlTrkTransport: TGLPanel
                Left = 0
                Top = 42
                Width = 952
                Height = 36
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 5
                object ibTrkTransport: TGLIconBar
                  Left = 8
                  Top = 4
                  Width = 272
                  Height = 28
                  ShowHint = True
                  Buttons = 'tostart;play;playpat;pause;stop;toend;record;totimeline'
                  Hints = 'Back to the beginning of the module;Play the module from the beginning (or continue after Pause);Play the pattern chosen in the pattern list on its own, over and over until Stop;Pause: hold the position, Play continues from there;Stop playback;Go to the last pattern in the module;Record: open the Recording view to arm tracks and record takes;Add the current tracker module to the Timeline (asks whether to keep it live as notation or convert it to an audio clip)'
                  CellWidth = 34
                  OnButtonClick = ibTrkTransportClick
                end
                object btnTrkMidiRec: TGLButton
                  Left = 296
                  Top = 5
                  Width = 140
                  Height = 26
                  Hint = 'MIDI record: notes played on the MIDI keyboard chosen under Settings are written into the pattern grid - at the cursor while stopped (chords fill neighbouring channels), at the playing row while the module plays'
                  Caption = 'MIDI record'
                  ParentShowHint = False
                  ShowHint = True
                  TabOrder = 1
                  Toggle = True
                end
              end
              object pnlTrkSequence: TGLPanel
                Left = 0
                Top = 78
                Width = 952
                Height = 58
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 2
                DoubleBuffered = True
                ParentDoubleBuffered = False
                object pbTrkSequence: TGLView
                  Left = 0
                  Top = 0
                  Width = 952
                  Height = 42
                  Align = alTop
                  Hint = 'Sequence: click a step to jump to its pattern, Ctrl+click to select several (Export Pattern to Timeline renders them together), double-click to change the pattern a step plays, right-click for more'
                  ShowHint = True
                  PopupMenu = pmTrkSeq
                  OnDblClick = pbTrkSequenceDblClick
                  OnMouseDown = pbTrkSequenceMouseDown
                  OnPaint = pbTrkSequencePaint
                end
                object sbTrkSeq: TGLScrollBar
                  Left = 0
                  Top = 42
                  Width = 952
                  Height = 16
                  Align = alTop
                  PageSize = 0
                  TabOrder = 0
                  OnChange = sbTrkSeqChange
                end
              end
              object pbTracker: TGLView
                Left = 0
                Top = 138
                Width = 952
                Height = 227
                Align = alClient
                PopupMenu = pmTrkGrid
                WantArrows = True
                OnMouseDown = pbTrackerMouseDown
                OnMouseMove = pbTrackerMouseMove
                OnMouseLeave = pbTrackerMouseLeave
                OnMouseUp = pbTrackerMouseUp
                OnMouseWheel = pbTrackerMouseWheel
                OnPaint = pbTrackerPaint
              end
              object sbTrkChn: TGLScrollBar
                Left = 0
                Top = 365
                Width = 952
                Height = 16
                Align = alBottom
                PageSize = 0
                TabOrder = 4
                OnChange = sbTrkChnChange
              end
              end
              object tsTrkInstruments: TGLPage
                Caption = 'Instruments'
                object pnlTrkInstrTop: TGLPanel
                  Left = 0
                  Top = 0
                  Width = 952
                  Height = 44
                  Align = alTop
                  BevelOuter = bvNone
                  TabOrder = 0
                  object lblTrkInstrSel: TGLLabel
                    Transparent = True
                    Left = 8
                    Top = 12
                    Width = 56
                    Height = 15
                    Caption = 'Instrument'
                  end
                  object cboTrkInstrSel: TGLCombo
                    Left = 76
                    Top = 8
                    Width = 260
                    Height = 23
                    TabOrder = 0
                    OnChange = cboTrkInstrSelChange
                  end
                  object ibTrkInstr: TGLIconBar
                    Left = 348
                    Top = 6
                    Width = 96
                    Height = 28
                    ShowHint = True
                    Buttons = 'add;export;wavedit'
                    Hints = 'Add to Timeline: bounce this instrument to a WAV in the Recordings folder and place it on the Timeline;Export sample: save as WAV, raw PCM or FLAC (WAV keeps loop points and all applied settings);WAV editor: edit this instrument''s sound (or double-click the waveform)'
                    OnButtonClick = ibTrkInstrClick
                  end
                end
                object pnlTrkInstrInfo: TGLPanel
                  Left = 0
                  Top = 44
                  Width = 952
                  Height = 24
                  Align = alTop
                  BevelOuter = bvNone
                  TabOrder = 1
                  object lblTrkInstrInfo: TGLLabel
                    Transparent = True
                    Left = 8
                    Top = 4
                    Width = 300
                    Height = 15
                    Caption = '(no instrument selected)'
                  end
                end
                object pbTrkInstrWave: TGLView
                  Left = 0
                  Top = 68
                  Width = 952
                  Height = 488
                  Align = alClient
                  OnPaint = pbTrkInstrWavePaint
                  OnDblClick = pbTrkInstrWaveDblClick
                end
              end
              end
            end
            object tabRecording: TGLPage
              Caption = 'Recording'
              ImageIndex = 9
              object sbRecording: TGLScrollBox
                Left = 0
                Top = 0
                Width = 952
                Height = 531
                Align = alClient
                TabOrder = 0
                object grpRecSetup: TGLGroup
                  Left = 8
                  Top = 4
                  Width = 920
                  Height = 134
                  Anchors = [akLeft, akTop, akRight]
                  Caption = ' Take Settings '
                  TabOrder = 0
                    object lblRecFormat: TGLLabel
                      Transparent = True
                      Left = 16
                      Top = 29
                      Width = 80
                      Height = 15
                      Caption = 'Take format'
                    end
                    object cboRecFormat: TGLCombo
                      Left = 104
                      Top = 26
                      Width = 130
                      Height = 23
                      TabOrder = 0
                    end
                    object lblRecPreRoll: TGLLabel
                      Transparent = True
                      Left = 262
                      Top = 29
                      Width = 70
                      Height = 15
                      Caption = 'Pre-roll (s)'
                    end
                    object edtRecPreRoll: TGLEdit
                      Left = 340
                      Top = 26
                      Width = 56
                      Height = 23
                      TabOrder = 1
                      Text = '0'
                    end
                    object lblRecCountIn: TGLLabel
                      Transparent = True
                      Left = 424
                      Top = 29
                      Width = 100
                      Height = 15
                      Caption = 'Count-in (beats)'
                    end
                    object edtRecCountIn: TGLEdit
                      Left = 530
                      Top = 26
                      Width = 56
                      Height = 23
                      TabOrder = 2
                      Text = '0'
                    end
                    object chkRecMonitor: TGLCheck
                      Left = 628
                      Top = 28
                      Width = 190
                      Height = 19
                      Caption = 'Input monitoring'
                      TabOrder = 3
                    end
                    object lblRecPunch: TGLLabel
                      Transparent = True
                      Left = 16
                      Top = 65
                      Width = 80
                      Height = 15
                      Caption = 'Punch'
                    end
                    object cboRecPunch: TGLCombo
                      Left = 104
                      Top = 62
                      Width = 130
                      Height = 23
                      TabOrder = 4
                      OnChange = cboRecPunchChange
                    end
                    object lblRecPunchIn: TGLLabel
                      Transparent = True
                      Left = 262
                      Top = 65
                      Width = 70
                      Height = 15
                      Caption = 'Punch in (s)'
                    end
                    object edtRecPunchIn: TGLEdit
                      Left = 340
                      Top = 62
                      Width = 56
                      Height = 23
                      TabOrder = 5
                      Text = '1.0'
                    end
                    object lblRecPunchOut: TGLLabel
                      Transparent = True
                      Left = 424
                      Top = 65
                      Width = 100
                      Height = 15
                      Caption = 'Punch out (s)'
                    end
                    object edtRecPunchOut: TGLEdit
                      Left = 530
                      Top = 62
                      Width = 56
                      Height = 23
                      TabOrder = 6
                      Text = '3.0'
                    end
                    object chkRecLoop: TGLCheck
                      Left = 16
                      Top = 100
                      Width = 120
                      Height = 19
                      Caption = 'Loop-record'
                      TabOrder = 7
                      OnClick = chkRecLoopClick
                    end
                    object lblRecLoopStart: TGLLabel
                      Transparent = True
                      Left = 262
                      Top = 101
                      Width = 76
                      Height = 15
                      Caption = 'Loop start (s)'
                    end
                    object edtRecLoopStart: TGLEdit
                      Left = 340
                      Top = 98
                      Width = 56
                      Height = 23
                      TabOrder = 8
                      Text = '0'
                    end
                    object lblRecLoopEnd: TGLLabel
                      Transparent = True
                      Left = 424
                      Top = 101
                      Width = 100
                      Height = 15
                      Caption = 'Loop end (s)'
                    end
                    object edtRecLoopEnd: TGLEdit
                      Left = 530
                      Top = 98
                      Width = 56
                      Height = 23
                      TabOrder = 9
                      Text = '2'
                    end
                end
                object grpRecControl: TGLGroup
                  Left = 8
                  Top = 146
                  Width = 920
                  Height = 122
                  Anchors = [akLeft, akTop, akRight]
                  Caption = ' Record '
                  TabOrder = 1
                    object btnRecArm: TGLButton
                      Left = 16
                      Top = 26
                      Width = 200
                      Height = 32
                      Caption = 'Start live recording'
                      TabOrder = 10
                      OnClick = btnRecArmClick
                    end
                    object btnRecCommit: TGLButton
                      Left = 224
                      Top = 26
                      Width = 170
                      Height = 32
                      Caption = 'Retry adding take'
                      TabOrder = 11
                      OnClick = btnRecCommitClick
                    end
                    object btnRecSaved: TGLButton
                      Left = 402
                      Top = 26
                      Width = 170
                      Height = 32
                      Caption = 'Add saved audio...'
                      TabOrder = 12
                      OnClick = btnRecSavedClick
                    end
                    object btnRecScan: TGLButton
                      Left = 580
                      Top = 26
                      Width = 210
                      Height = 32
                      Caption = 'Recover unfinished takes'
                      TabOrder = 13
                      OnClick = btnRecScanClick
                    end
                    object lblRecMicState: TGLLabel
                      Transparent = True
                      Left = 16
                      Top = 70
                      Width = 888
                      Height = 18
                      Anchors = [akLeft, akTop, akRight]
                      Caption = 'Microphone: OFF | Recording: OFF'
                      ShowHint = True
                    end
                    object lblRecDestination: TGLLabel
                      Transparent = True
                      Left = 16
                      Top = 92
                      Width = 888
                      Height = 18
                      Anchors = [akLeft, akTop, akRight]
                      Caption = 'Full input until Stop. Select input device and enable capture in Settings.'
                    end
                end
                object grpRecTakes: TGLGroup
                  Left = 8
                  Top = 276
                  Width = 920
                  Height = 372
                  Anchors = [akLeft, akTop, akRight]
                  Caption = ' Takes and Comp '
                  TabOrder = 2
                    object btnRecSaveTake: TGLButton
                      Left = 16
                      Top = 24
                      Width = 190
                      Height = 28
                      Caption = 'Save Selected Take As...'
                      TabOrder = 14
                      OnClick = btnRecSaveTakeClick
                    end
                    object btnRecAddTakeToTimeline: TGLButton
                      Left = 214
                      Top = 24
                      Width = 220
                      Height = 28
                      Caption = 'Add Selected Take to Timeline'
                      TabOrder = 15
                      OnClick = btnRecAddTakeToTimelineClick
                    end
                    object btnRecCommitComp: TGLButton
                      Left = 442
                      Top = 24
                      Width = 190
                      Height = 28
                      Caption = 'Commit Comp to Timeline'
                      TabOrder = 16
                      OnClick = btnRecCommitCompClick
                    end
                    object btnRecResetComp: TGLButton
                      Left = 640
                      Top = 24
                      Width = 120
                      Height = 28
                      Caption = 'Reset Comp'
                      TabOrder = 17
                      OnClick = btnRecResetCompClick
                    end
                    object pbRecTakes: TGLView
                      Left = 12
                      Top = 60
                      Width = 896
                      Height = 300
                      Anchors = [akLeft, akTop, akRight]
                      PopupMenu = pmRecording
                      OnMouseDown = pbRecTakesMouseDown
                      OnMouseMove = pbRecTakesMouseMove
                      OnMouseUp = pbRecTakesMouseUp
                      OnPaint = pbRecTakesPaint
                    end
                end
              end
            end
            object tabFoley: TGLPage
              Caption = 'Foley'
              object sbFoley: TGLScrollBox
                Left = 0
                Top = 0
                Width = 952
                Height = 531
                Align = alClient
                TabOrder = 0
                object grpFoley: TGLGroup
                  Left = 8
                  Top = 4
                  Width = 920
                  Height = 326
                  Anchors = [akLeft, akTop, akRight]
                  Caption = ' Foley Sampler '
                  TabOrder = 0
                  object btnFoleyPad1: TGLButton
                    Left = 16
                    Top = 28
                    Width = 116
                    Height = 52
                    Tag = 0
                    Caption = 'Pad'
                    Hint = 'Foley pad 1 (key 1): click it, or press its key, to play the loaded sound.'
                    TabOrder = 0
                    OnClick = btnFoleyPadClick
                  end
                  object btnFoleyPad2: TGLButton
                    Left = 140
                    Top = 28
                    Width = 116
                    Height = 52
                    Tag = 1
                    Caption = 'Pad'
                    Hint = 'Foley pad 2 (key 2): click it, or press its key, to play the loaded sound.'
                    TabOrder = 1
                    OnClick = btnFoleyPadClick
                  end
                  object btnFoleyPad3: TGLButton
                    Left = 264
                    Top = 28
                    Width = 116
                    Height = 52
                    Tag = 2
                    Caption = 'Pad'
                    Hint = 'Foley pad 3 (key 3): click it, or press its key, to play the loaded sound.'
                    TabOrder = 2
                    OnClick = btnFoleyPadClick
                  end
                  object btnFoleyPad4: TGLButton
                    Left = 388
                    Top = 28
                    Width = 116
                    Height = 52
                    Tag = 3
                    Caption = 'Pad'
                    Hint = 'Foley pad 4 (key 4): click it, or press its key, to play the loaded sound.'
                    TabOrder = 3
                    OnClick = btnFoleyPadClick
                  end
                  object btnFoleyPad5: TGLButton
                    Left = 16
                    Top = 86
                    Width = 116
                    Height = 52
                    Tag = 4
                    Caption = 'Pad'
                    Hint = 'Foley pad 5 (key Q): click it, or press its key, to play the loaded sound.'
                    TabOrder = 4
                    OnClick = btnFoleyPadClick
                  end
                  object btnFoleyPad6: TGLButton
                    Left = 140
                    Top = 86
                    Width = 116
                    Height = 52
                    Tag = 5
                    Caption = 'Pad'
                    Hint = 'Foley pad 6 (key W): click it, or press its key, to play the loaded sound.'
                    TabOrder = 5
                    OnClick = btnFoleyPadClick
                  end
                  object btnFoleyPad7: TGLButton
                    Left = 264
                    Top = 86
                    Width = 116
                    Height = 52
                    Tag = 6
                    Caption = 'Pad'
                    Hint = 'Foley pad 7 (key E): click it, or press its key, to play the loaded sound.'
                    TabOrder = 6
                    OnClick = btnFoleyPadClick
                  end
                  object btnFoleyPad8: TGLButton
                    Left = 388
                    Top = 86
                    Width = 116
                    Height = 52
                    Tag = 7
                    Caption = 'Pad'
                    Hint = 'Foley pad 8 (key R): click it, or press its key, to play the loaded sound.'
                    TabOrder = 7
                    OnClick = btnFoleyPadClick
                  end
                  object btnFoleyPad9: TGLButton
                    Left = 16
                    Top = 144
                    Width = 116
                    Height = 52
                    Tag = 8
                    Caption = 'Pad'
                    Hint = 'Foley pad 9 (key A): click it, or press its key, to play the loaded sound.'
                    TabOrder = 8
                    OnClick = btnFoleyPadClick
                  end
                  object btnFoleyPad10: TGLButton
                    Left = 140
                    Top = 144
                    Width = 116
                    Height = 52
                    Tag = 9
                    Caption = 'Pad'
                    Hint = 'Foley pad 10 (key S): click it, or press its key, to play the loaded sound.'
                    TabOrder = 9
                    OnClick = btnFoleyPadClick
                  end
                  object btnFoleyPad11: TGLButton
                    Left = 264
                    Top = 144
                    Width = 116
                    Height = 52
                    Tag = 10
                    Caption = 'Pad'
                    Hint = 'Foley pad 11 (key D): click it, or press its key, to play the loaded sound.'
                    TabOrder = 10
                    OnClick = btnFoleyPadClick
                  end
                  object btnFoleyPad12: TGLButton
                    Left = 388
                    Top = 144
                    Width = 116
                    Height = 52
                    Tag = 11
                    Caption = 'Pad'
                    Hint = 'Foley pad 12 (key F): click it, or press its key, to play the loaded sound.'
                    TabOrder = 11
                    OnClick = btnFoleyPadClick
                  end
                  object btnFoleyPad13: TGLButton
                    Left = 16
                    Top = 202
                    Width = 116
                    Height = 52
                    Tag = 12
                    Caption = 'Pad'
                    Hint = 'Foley pad 13 (key Z): click it, or press its key, to play the loaded sound.'
                    TabOrder = 12
                    OnClick = btnFoleyPadClick
                  end
                  object btnFoleyPad14: TGLButton
                    Left = 140
                    Top = 202
                    Width = 116
                    Height = 52
                    Tag = 13
                    Caption = 'Pad'
                    Hint = 'Foley pad 14 (key X): click it, or press its key, to play the loaded sound.'
                    TabOrder = 13
                    OnClick = btnFoleyPadClick
                  end
                  object btnFoleyPad15: TGLButton
                    Left = 264
                    Top = 202
                    Width = 116
                    Height = 52
                    Tag = 14
                    Caption = 'Pad'
                    Hint = 'Foley pad 15 (key C): click it, or press its key, to play the loaded sound.'
                    TabOrder = 14
                    OnClick = btnFoleyPadClick
                  end
                  object btnFoleyPad16: TGLButton
                    Left = 388
                    Top = 202
                    Width = 116
                    Height = 52
                    Tag = 15
                    Caption = 'Pad'
                    Hint = 'Foley pad 16 (key V): click it, or press its key, to play the loaded sound.'
                    TabOrder = 15
                    OnClick = btnFoleyPadClick
                  end
                  object lblFoleySelected: TGLLabel
                    Transparent = True
                    Left = 540
                    Top = 30
                    Width = 360
                    Height = 15
                    Caption = 'Pad'
                  end
                  object btnFoleyLoad: TGLButton
                    Left = 540
                    Top = 54
                    Width = 130
                    Height = 26
                    Caption = 'Load into pad...'
                    Hint = 'Load a sound file (WAV or MP3) into the selected pad.'
                    TabOrder = 16
                    OnClick = btnFoleyLoadClick
                  end
                  object btnFoleyClear: TGLButton
                    Left = 678
                    Top = 54
                    Width = 90
                    Height = 26
                    Caption = 'Clear pad'
                    Hint = 'Remove the sound from the selected pad.'
                    TabOrder = 17
                    OnClick = btnFoleyClearClick
                  end
                  object btnFoleyPlace: TGLButton
                    Left = 540
                    Top = 88
                    Width = 228
                    Height = 26
                    Caption = 'Place pad at playhead'
                    Hint = 'Place the selected pad''s sound on the Timeline at the playhead.'
                    TabOrder = 18
                    OnClick = btnFoleyPlaceClick
                  end
                  object chkFoleyTimeline: TGLCheck
                    Left = 540
                    Top = 126
                    Width = 370
                    Height = 19
                    Caption = 'A pad key adds its sound at the playhead (splits the clip it lands in)'
                    Checked = True
                    Hint = 'Pressing a pad key puts that pad''s sound on the selected Timeline lane at the playhead. If the playhead is inside a clip, the clip is split and the sound goes between the two halves.'
                    TabOrder = 19
                  end
                  object chkFoleyRecord: TGLCheck
                    Left = 540
                    Top = 156
                    Width = 370
                    Height = 19
                    Caption = 'Record hits while the Timeline plays'
                    Hint = 'While the Timeline plays, note the playhead time of every pad hit so Add hits to Timeline can lay them out as clips.'
                    TabOrder = 20
                  end
                  object lblFoleyHits: TGLLabel
                    Transparent = True
                    Left = 540
                    Top = 186
                    Width = 200
                    Height = 15
                    Caption = '0 hit(s) recorded'
                  end
                  object btnFoleyCommit: TGLButton
                    Left = 540
                    Top = 212
                    Width = 226
                    Height = 26
                    Caption = 'Add hits to Timeline'
                    Hint = 'Add every recorded hit to the Timeline as clips (one track per pad).'
                    Enabled = False
                    TabOrder = 21
                    OnClick = btnFoleyCommitClick
                  end
                  object btnFoleyDiscard: TGLButton
                    Left = 774
                    Top = 212
                    Width = 120
                    Height = 26
                    Caption = 'Discard hits'
                    Hint = 'Throw away the recorded hits without adding them.'
                    Enabled = False
                    TabOrder = 22
                    OnClick = btnFoleyDiscardClick
                  end
                  object lblFoleyHelp: TGLLabel
                    Transparent = True
                    Left = 16
                    Top = 276
                    Width = 880
                    Height = 15
                    Caption = 'Keyboard: 1 2 3 4 / Q W E R / A S D F / Z X C V play pads 1-16 while this page is showing. Pads play through the Output device chosen in Settings.'
                  end
                end
              end
            end
            object tabDockAi: TGLPage
              Caption = 'AI/SI'
            object pcAiMain: TGLPageControl
              Left = 0
              Top = 0
              Width = 952
              Height = 380
              Align = alTop
              TabOrder = 0
              object tsAiSelect: TGLPage
                Caption = 'AI/SI Selection'
                object lblAiProvider: TGLLabel
                  Transparent = True
                  Left = 8
                  Top = 6
                  Width = 40
                  Height = 15
                  Caption = 'Provider'
                end
                object lblAiKey: TGLLabel
                  Transparent = True
                  Left = 200
                  Top = 6
                  Width = 40
                  Height = 15
                  Caption = 'API key'
                end
                object lblAiModel: TGLLabel
                  Transparent = True
                  Left = 520
                  Top = 6
                  Width = 31
                  Height = 15
                  Caption = 'Model'
                end
                object cboAiProvider: TGLCombo
                  Left = 8
                  Top = 22
                  Width = 180
                  Height = 23
                  TabOrder = 0
                  OnChange = cboAiProviderChange
                end
                object edtAiApiKey: TGLEdit
                  Left = 200
                  Top = 22
                  Width = 300
                  Height = 23
                  PasswordChar = '*'
                  TabOrder = 1
                end
                object cboAiModel: TGLCombo
                  Style = csDropDown
                  Left = 520
                  Top = 22
                  Width = 280
                  Height = 23
                  TabOrder = 2
                  OnChange = cboAiModelChange
                end
                object btnAiTest: TGLButton
                  Left = 808
                  Top = 21
                  Width = 75
                  Height = 25
                  Caption = 'Test'
                  TabOrder = 3
                  Hint = 'Verify the stored API key against this provider and fetch its available models'
                  ShowHint = True
                  ParentShowHint = False
                  OnClick = btnAiTestClick
                end
                object btnAiSave: TGLButton
                  Left = 8
                  Top = 50
                  Width = 90
                  Height = 25
                  Caption = 'Save Key'
                  TabOrder = 4
                  OnClick = btnAiSaveClick
                end
                object btnAiDelete: TGLButton
                  Left = 104
                  Top = 50
                  Width = 90
                  Height = 25
                  Caption = 'Delete Key'
                  TabOrder = 5
                  OnClick = btnAiDeleteClick
                end
              end
              object tsAiMcp: TGLPage
                Caption = 'MCP'
                object lblAiMcpName: TGLLabel
                  Transparent = True
                  Left = 8
                  Top = 8
                  Width = 62
                  Height = 15
                  Caption = 'MCP name'
                end
                object lblAiMcpCmd: TGLLabel
                  Transparent = True
                  Left = 200
                  Top = 8
                  Width = 106
                  Height = 15
                  Caption = 'MCP command line'
                end
                object edtAiMcpName: TGLEdit
                  Left = 8
                  Top = 24
                  Width = 180
                  Height = 23
                  TabOrder = 0
                end
                object edtAiMcpCommand: TGLEdit
                  Left = 200
                  Top = 24
                  Width = 392
                  Height = 23
                  TabOrder = 1
                end
                object lblAiMcpToken: TGLLabel
                  Transparent = True
                  Left = 690
                  Top = 8
                  Width = 80
                  Height = 15
                  Caption = 'HTTP auth token'
                end
                object edtAiMcpToken: TGLEdit
                  Left = 684
                  Top = 24
                  Width = 200
                  Height = 23
                  PasswordChar = '*'
                  TabOrder = 20
                end
                object btnAiMcpTest: TGLButton
                  Left = 600
                  Top = 23
                  Width = 75
                  Height = 25
                  Caption = 'Test'
                  TabOrder = 2
                  OnClick = btnAiMcpTestClick
                end
                object lblAiMcpHint: TGLLabel
                  Transparent = True
                  Left = 8
                  Top = 52
                  Width = 400
                  Height = 15
                  Caption = 'MCP command line starting with http:// or https:// connects over HTTP'
                  Font.Color = clGrayText
                  Font.Height = -11
                  ParentFont = False
                end
                object chkAiMcpExpose: TGLCheck
                  Left = 8
                  Top = 76
                  Width = 260
                  Height = 19
                  Caption = 'Expose UDAW as an MCP server'
                  TabOrder = 3
                  OnClick = chkAiMcpExposeClick
                end
                object lblAiMcpExposePort: TGLLabel
                  Transparent = True
                  Left = 276
                  Top = 80
                  Width = 24
                  Height = 15
                  Caption = 'Port'
                end
                object edtAiMcpExposePort: TGLEdit
                  Left = 304
                  Top = 76
                  Width = 60
                  Height = 23
                  TabOrder = 4
                  Text = '8765'
                end
                object chkAiMcpAllowDestructive: TGLCheck
                  Left = 380
                  Top = 76
                  Width = 220
                  Height = 19
                  Caption = 'Allow destructive tools'
                  TabOrder = 5
                end
                object lblAiMcpBind: TGLLabel
                  Transparent = True
                  Left = 608
                  Top = 80
                  Width = 28
                  Height = 15
                  Caption = 'Bind'
                end
                object edtAiMcpBind: TGLEdit
                  Left = 640
                  Top = 76
                  Width = 100
                  Height = 23
                  Hint = '127.0.0.1 = local only. 0.0.0.0 = every network interface (LAN/remote) - use a firewall rule to control who may reach it.'
                  ParentShowHint = False
                  ShowHint = True
                  TabOrder = 6
                  Text = '127.0.0.1'
                end
                object chkAiMcpTls: TGLCheck
                  Left = 8
                  Top = 108
                  Width = 210
                  Height = 19
                  Caption = 'HTTPS (TLS) for remote agents'
                  Hint = 'Adds an encrypted https listener next to the local one, for AI/SI agents outside your network. Needs an auth token (always on), a PEM certificate + key, and a port-forward / tunnel to this PC.'
                  ParentShowHint = False
                  ShowHint = True
                  TabOrder = 8
                end
                object lblAiMcpTlsPort: TGLLabel
                  Transparent = True
                  Left = 226
                  Top = 112
                  Width = 44
                  Height = 15
                  Caption = 'TLS port'
                end
                object edtAiMcpTlsPort: TGLEdit
                  Left = 274
                  Top = 108
                  Width = 56
                  Height = 23
                  TabOrder = 9
                  Text = '8766'
                end
                object lblAiMcpCert: TGLLabel
                  Transparent = True
                  Left = 342
                  Top = 112
                  Width = 60
                  Height = 15
                  Caption = 'Cert (PEM)'
                end
                object edtAiMcpCert: TGLEdit
                  Left = 406
                  Top = 108
                  Width = 210
                  Height = 23
                  TabOrder = 10
                end
                object lblAiMcpKey: TGLLabel
                  Transparent = True
                  Left = 626
                  Top = 112
                  Width = 56
                  Height = 15
                  Caption = 'Key (PEM)'
                end
                object edtAiMcpKey: TGLEdit
                  Left = 686
                  Top = 108
                  Width = 210
                  Height = 23
                  TabOrder = 11
                end
                object btnAiMcpTestLocal: TGLButton
                  Left = 8
                  Top = 138
                  Width = 130
                  Height = 25
                  Caption = 'Test local'
                  Hint = 'Connects to this UDAW MCP server on 127.0.0.1 exactly like a local agent would and reports every stage.'
                  ParentShowHint = False
                  ShowHint = True
                  TabOrder = 12
                  OnClick = btnAiMcpTestLocalClick
                end
                object btnAiMcpTestTls: TGLButton
                  Left = 146
                  Top = 138
                  Width = 130
                  Height = 25
                  Caption = 'Test TLS / URL'
                  Hint = 'Tests the URL on the right (blank = the local https listener): DNS/TCP, TLS handshake + certificate, token, MCP handshake, tool list.'
                  ParentShowHint = False
                  ShowHint = True
                  TabOrder = 13
                  OnClick = btnAiMcpTestTlsClick
                end
                object edtAiMcpTestUrl: TGLEdit
                  Left = 284
                  Top = 139
                  Width = 320
                  Height = 23
                  TextHint = 'https://your-host.example.com:8766/mcp  (blank = local https listener)'
                  TabOrder = 14
                end
                object chkAiMcpSelfSigned: TGLCheck
                  Left = 612
                  Top = 139
                  Width = 260
                  Height = 19
                  Caption = 'Allow self-signed certificate (test only)'
                  TabOrder = 15
                end
                object lstAiMcpServers: TGLList
                  Left = 0
                  Top = 240
                  Width = 952
                  Height = 90
                  Align = alBottom
                  ItemHeight = 15
                  TabOrder = 7
                  PopupMenu = pmAi
                end
              end
              object tsAiRecordings: TGLPage
                Caption = 'Recordings'
                object lblSunoRefHint: TGLLabel
                  Align = alTop
                  AlignWithMargins = True
                  Margins.Left = 8
                  Margins.Top = 8
                  Margins.Right = 8
                  Margins.Bottom = 9
                  Transparent = True
                  Left = 8
                  Top = 8
                  Width = 900
                  Height = 15
                  Caption = 'Recordings available to Suno as reference audio for Cover/Extend (Generation tab). Add existing files or record new ones here.'
                end
                object lstSunoRefs: TGLList
                  Align = alLeft
                  AlignWithMargins = True
                  Margins.Left = 8
                  Margins.Top = 0
                  Margins.Right = 12
                  Margins.Bottom = 8
                  Left = 8
                  Top = 32
                  Width = 560
                  Height = 300
                  ItemHeight = 15
                  TabOrder = 0
                end
                object btnSunoRefAdd: TGLButton
                  Left = 580
                  Top = 32
                  Width = 150
                  Height = 25
                  Caption = 'Add Recording...'
                  TabOrder = 1
                  OnClick = btnSunoRefAddClick
                end
                object btnSunoRefRemove: TGLButton
                  Left = 580
                  Top = 64
                  Width = 150
                  Height = 25
                  Caption = 'Remove'
                  TabOrder = 2
                  OnClick = btnSunoRefRemoveClick
                end
                object btnSunoRefRefresh: TGLButton
                  Left = 580
                  Top = 96
                  Width = 150
                  Height = 25
                  Caption = 'Refresh from Folder'
                  TabOrder = 3
                  OnClick = btnSunoRefRefreshClick
                end
                object btnSunoRefRecord: TGLButton
                  Left = 580
                  Top = 136
                  Width = 150
                  Height = 25
                  Caption = 'Record'
                  Hint = 'Records from the current input device at full quality (native channels/rate) into the Recordings folder and adds it to the list above.'
                  ShowHint = True
                  ParentShowHint = False
                  TabOrder = 4
                  OnClick = btnSunoRefRecordClick
                end
              end
              object tsAiLyrics: TGLPage
                Caption = 'Lyrics and Styles'
                object lblSunoPrompt: TGLLabel
                  Transparent = True
                  Left = 8
                  Top = 10
                  Width = 70
                  Height = 15
                  Caption = 'Suno prompt'
                end
                object lblSunoLyricsCount: TGLLabel
                  Transparent = True
                  Left = 180
                  Top = 206
                  Width = 120
                  Height = 15
                  Caption = '0 / 5000 characters'
                  Visible = False
                end
                object lblSunoStyle: TGLLabel
                  Left = 8
                  Top = 233
                  Anchors = [akLeft, akBottom]
                  Caption = 'Style / BPM'
                  Visible = False
                end
                object lblSunoTitle: TGLLabel
                  Left = 8
                  Top = 326
                  Anchors = [akLeft, akBottom]
                  Caption = 'Title'
                  Visible = False
                end
                object edtSunoPrompt: TGLEdit
                  Left = 88
                  Top = 7
                  Width = 640
                  Height = 23
                  Anchors = [akLeft, akTop, akRight]
                  TabOrder = 0
                end
                object memSunoLyrics: TGLMemo
                  ReadOnly = False
                  Left = 88
                  Top = 7
                  Width = 640
                  Height = 190
                  Anchors = [akLeft, akTop, akRight, akBottom]
                  Hint = 'Full song lyrics, e.g. with [Verse]/[Chorus] section tags. Suno custom mode caps this at 5000 characters.'
                  ShowHint = True
                  ParentShowHint = False
                  MaxLength = 5000
                  PopupMenu = pmSunoLyrics
                  PlainText = True
                  ScrollBars = ssVertical
                  TabOrder = 1
                  Visible = False
                  OnChange = memSunoLyricsChange
                end
                object chkSunoInstrumental: TGLCheck
                  Left = 740
                  Top = 9
                  Anchors = [akTop, akRight]
                  Width = 100
                  Height = 19
                  Caption = 'Instrumental'
                  TabOrder = 2
                end
                object chkSunoCustom: TGLCheck
                  Left = 8
                  Top = 204
                  Anchors = [akLeft, akBottom]
                  Width = 160
                  Height = 19
                  Caption = 'Custom lyrics/style'
                  TabOrder = 3
                  OnClick = chkSunoCustomClick
                end
                object edtSunoStyle: TGLMemo
                  ReadOnly = False
                  Left = 88
                  Top = 230
                  Anchors = [akLeft, akRight, akBottom]
                  Width = 640
                  Height = 84
                  Hint = 'Custom mode style tags, for example: ambient, piano, 120 bpm. Tempo is a prompt hint, not guaranteed alignment.'
                  ShowHint = True
                  ParentShowHint = False
                  PlainText = True
                  ScrollBars = ssVertical
                  TabOrder = 4
                  Visible = False
                end
                object edtSunoTitle: TGLEdit
                  Left = 88
                  Top = 322
                  Anchors = [akLeft, akBottom]
                  Width = 300
                  Height = 23
                  TabOrder = 5
                  Visible = False
                end
              end
              object tsAiGeneration: TGLPage
                Caption = 'Generation'
                object pnlAiChat: TGLPanel
                  Left = 0
                  Top = 0
                  Width = 952
                  Height = 74
                  Align = alTop
                  BevelOuter = bvNone
                  TabOrder = 0
                  object edtAiPrompt: TGLEdit
                    Left = 8
                    Top = 8
                    Width = 680
                    Height = 23
                    TabOrder = 0
                  end
                  object btnAiSend: TGLButton
                    Left = 696
                    Top = 7
                    Width = 75
                    Height = 25
                    Caption = 'Send'
                    Default = True
                    TabOrder = 1
                    OnClick = btnAiSendClick
                  end
                  object btnAiClear: TGLButton
                    Left = 776
                    Top = 7
                    Width = 75
                    Height = 25
                    Caption = 'Clear'
                    TabOrder = 2
                    OnClick = btnAiClearClick
                  end
                  object btnAiGenerateTune: TGLButton
                    Left = 8
                    Top = 40
                    Width = 280
                    Height = 25
                    Caption = 'Generate Tune from Browser Library'
                    Hint = 'Ask the AI/SI to plan and build a full timeline arrangement using files from your Browser folders'
                    ShowHint = True
                    ParentShowHint = False
                    TabOrder = 3
                    OnClick = btnAiGenerateTuneClick
                  end
                end
                object pnlAiLuma: TGLPanel
                  Left = 0
                  Top = 0
                  Width = 952
                  Height = 276
                  Align = alTop
                  BevelOuter = bvNone
                  TabOrder = 2
                  Visible = False
                  object lblLumaKind: TGLLabel
                    Transparent = True
                    Left = 8
                    Top = 14
                    Caption = 'Media type'
                  end
                  object cboLumaKind: TGLCombo
                    Left = 124
                    Top = 10
                    Width = 120
                    Height = 23
                    ItemIndex = 0
                    TabOrder = 0
                    Items.Strings = (
                      'Video'
                      'Image')
                    OnChange = cboLumaKindChange
                  end
                  object lblLumaModel: TGLLabel
                    Transparent = True
                    Left = 260
                    Top = 14
                    Caption = 'Model'
                  end
                  object cboLumaModel: TGLCombo
                    Left = 304
                    Top = 10
                    Width = 150
                    Height = 23
                    ItemIndex = 0
                    TabOrder = 1
                    Items.Strings = (
                      'ray-2'
                      'ray-flash-2')
                  end
                  object btnLumaTest: TGLButton
                    Left = 470
                    Top = 9
                    Width = 130
                    Height = 25
                    Caption = 'Test (credits)'
                    TabOrder = 2
                    OnClick = btnLumaTestClick
                  end
                  object lblLumaPrompt: TGLLabel
                    Transparent = True
                    Left = 8
                    Top = 46
                    Caption = 'Prompt'
                  end
                  object edtLumaPrompt: TGLEdit
                    Left = 124
                    Top = 42
                    Width = 560
                    Height = 23
                    Hint = 'Describe the video or image to generate.'
                    ShowHint = True
                    TabOrder = 3
                  end
                  object lblLumaAspect: TGLLabel
                    Transparent = True
                    Left = 8
                    Top = 78
                    Caption = 'Aspect ratio'
                  end
                  object cboLumaAspect: TGLCombo
                    Left = 124
                    Top = 74
                    Width = 80
                    Height = 23
                    ItemIndex = 0
                    TabOrder = 4
                    Items.Strings = (
                      '16:9'
                      '1:1'
                      '9:16'
                      '4:3'
                      '3:4'
                      '21:9'
                      '9:21')
                  end
                  object lblLumaResolution: TGLLabel
                    Transparent = True
                    Left = 224
                    Top = 78
                    Caption = 'Resolution'
                  end
                  object cboLumaResolution: TGLCombo
                    Left = 290
                    Top = 74
                    Width = 80
                    Height = 23
                    ItemIndex = 1
                    TabOrder = 5
                    Items.Strings = (
                      '540p'
                      '720p'
                      '1080p'
                      '4k')
                  end
                  object lblLumaDuration: TGLLabel
                    Transparent = True
                    Left = 388
                    Top = 78
                    Caption = 'Duration'
                  end
                  object cboLumaDuration: TGLCombo
                    Left = 444
                    Top = 74
                    Width = 60
                    Height = 23
                    ItemIndex = 0
                    TabOrder = 6
                    Items.Strings = (
                      '5s'
                      '9s')
                  end
                  object lblLumaFormat: TGLLabel
                    Transparent = True
                    Left = 224
                    Top = 78
                    Caption = 'Format'
                  end
                  object cboLumaFormat: TGLCombo
                    Left = 290
                    Top = 74
                    Width = 80
                    Height = 23
                    ItemIndex = 0
                    TabOrder = 7
                    Items.Strings = (
                      'jpg'
                      'png')
                  end
                  object chkLumaLoop: TGLCheck
                    Left = 524
                    Top = 76
                    Width = 60
                    Height = 17
                    Caption = 'Loop'
                    TabOrder = 8
                  end
                  object lblLumaStartFrame: TGLLabel
                    Transparent = True
                    Left = 8
                    Top = 110
                    Caption = 'Start frame'
                  end
                  object edtLumaStartFrame: TGLEdit
                    Left = 124
                    Top = 106
                    Width = 560
                    Height = 23
                    Hint = 'Public HTTPS image URL (Luma only accepts CDN/web URLs, not local files).'
                    ShowHint = True
                    TabOrder = 9
                  end
                  object lblLumaEndFrame: TGLLabel
                    Transparent = True
                    Left = 8
                    Top = 142
                    Caption = 'End frame'
                  end
                  object edtLumaEndFrame: TGLEdit
                    Left = 124
                    Top = 138
                    Width = 560
                    Height = 23
                    Hint = 'Public HTTPS image URL (Luma only accepts CDN/web URLs, not local files).'
                    ShowHint = True
                    TabOrder = 10
                  end
                  object lblLumaImageRef: TGLLabel
                    Transparent = True
                    Left = 8
                    Top = 110
                    Caption = 'Image reference'
                  end
                  object edtLumaImageRef: TGLEdit
                    Left = 124
                    Top = 106
                    Width = 560
                    Height = 23
                    Hint = 'Public HTTPS image URL (Luma only accepts CDN/web URLs, not local files).'
                    ShowHint = True
                    TabOrder = 11
                  end
                  object lblLumaImageRefWeight: TGLLabel
                    Transparent = True
                    Left = 696
                    Top = 78
                    Caption = 'Ref. weight'
                  end
                  object edtLumaImageRefWeight: TGLEdit
                    Left = 696
                    Top = 106
                    Width = 50
                    Height = 23
                    Hint = 'Influence 0.0 - 1.0'
                    ShowHint = True
                    TabOrder = 12
                    Text = '0.85'
                  end
                  object lblLumaStyleRef: TGLLabel
                    Transparent = True
                    Left = 8
                    Top = 142
                    Caption = 'Style reference'
                  end
                  object edtLumaStyleRef: TGLEdit
                    Left = 124
                    Top = 138
                    Width = 560
                    Height = 23
                    Hint = 'Public HTTPS image URL (Luma only accepts CDN/web URLs, not local files).'
                    ShowHint = True
                    TabOrder = 13
                  end
                  object edtLumaStyleWeight: TGLEdit
                    Left = 696
                    Top = 138
                    Width = 50
                    Height = 23
                    Hint = 'Influence 0.0 - 1.0'
                    ShowHint = True
                    TabOrder = 14
                    Text = '0.8'
                  end
                  object lblLumaCharRef: TGLLabel
                    Transparent = True
                    Left = 8
                    Top = 174
                    Caption = 'Character reference'
                  end
                  object edtLumaCharRef: TGLEdit
                    Left = 124
                    Top = 170
                    Width = 560
                    Height = 23
                    Hint = 'Public HTTPS URL of a face/character image (identity0).'
                    ShowHint = True
                    TabOrder = 15
                  end
                  object lblLumaModifyRef: TGLLabel
                    Transparent = True
                    Left = 8
                    Top = 206
                    Caption = 'Modify image'
                  end
                  object edtLumaModifyRef: TGLEdit
                    Left = 124
                    Top = 202
                    Width = 560
                    Height = 23
                    Hint = 'Public HTTPS URL of an image to modify with the prompt.'
                    ShowHint = True
                    TabOrder = 16
                  end
                  object edtLumaModifyWeight: TGLEdit
                    Left = 696
                    Top = 202
                    Width = 50
                    Height = 23
                    Hint = 'Closeness to input 0.0 - 1.0 (use 0.0-0.1 for colour changes)'
                    ShowHint = True
                    TabOrder = 17
                    Text = '1.0'
                  end
                  object lblLumaConcepts: TGLLabel
                    Transparent = True
                    Left = 8
                    Top = 174
                    Caption = 'Camera concepts'
                  end
                  object lstLumaConcepts: TGLList
                    Left = 124
                    Top = 170
                    Width = 440
                    Height = 60
                    ItemHeight = 15
                    MultiSelect = True
                    TabOrder = 20
                  end
                  object btnLumaConcepts: TGLButton
                    Left = 572
                    Top = 170
                    Width = 112
                    Height = 25
                    Caption = 'Load concepts'
                    TabOrder = 21
                    OnClick = btnLumaConceptsClick
                  end
                  object btnLumaOpen: TGLButton
                    Left = 219
                    Top = 240
                    Width = 110
                    Height = 25
                    Caption = 'Open result'
                    Enabled = False
                    TabOrder = 22
                    OnClick = btnLumaOpenClick
                  end
                  object btnLumaGenerate: TGLButton
                    Left = 8
                    Top = 240
                    Width = 120
                    Height = 25
                    Caption = 'Generate'
                    TabOrder = 18
                    OnClick = btnLumaGenerateClick
                  end
                  object chkLumaTabOnly: TGLCheck
                    Left = 224
                    Top = 244
                    Width = 300
                    Height = 17
                    Caption = 'Music Tabular Only (PDF to AI\Rendered)'
                    TabOrder = 20
                  end
                  object btnLumaCancel: TGLButton
                    Left = 136
                    Top = 240
                    Width = 75
                    Height = 25
                    Caption = 'Cancel'
                    TabOrder = 19
                    OnClick = btnLumaCancelClick
                  end
                end
                object pnlAiSuno: TGLPanel
                  Left = 0
                  Top = 74
                  Width = 952
                  Height = 180
                  Align = alTop
                  BevelOuter = bvNone
                  TabOrder = 1
                  object lblSunoBaseUrl: TGLLabel
                    Transparent = True
                    Left = 8
                    Top = 13
                    Width = 70
                    Height = 15
                    Caption = 'Suno proxy'
                  end
                  object edtSunoBaseUrl: TGLEdit
                    Left = 88
                    Top = 10
                    Width = 300
                    Height = 23
                    Hint = 'Base URL for the selected API type, without /api routes. Local proxy: http://localhost:3000. Managed: use the base URL from your provider dashboard.'
                    ParentShowHint = False
                    ShowHint = True
                    TabOrder = 0
                    Enabled = False
                    Text = 'https://apibox.erweima.ai'
                  end
                  object btnSunoTest: TGLButton
                    Left = 396
                    Top = 9
                    Width = 75
                    Height = 25
                    Caption = 'Test'
                    TabOrder = 1
                    OnClick = btnSunoTestClick
                  end
                  object lblSunoApi: TGLLabel
                    Left = 8
                    Top = 46
                    Caption = 'API type'
                  end
                  object cboSunoApi: TGLCombo
                    Left = 88
                    Top = 42
                    Width = 240
                    Height = 23
                    ItemIndex = 1
                    Enabled = False
                    Items.Strings = (
                      'Self-hosted gcui-art/suno-api'
                      'Managed SunoAPI.org')
                    TabOrder = 2
                    OnChange = cboSunoApiChange
                  end
                  object lblSunoModel: TGLLabel
                    Left = 340
                    Top = 46
                    Caption = 'Model'
                  end
                  object cboSunoModel: TGLCombo
                    Left = 390
                    Top = 42
                    Width = 120
                    Height = 23
                    Hint = 'AI/SI model version. V6 is SunoAPI.org'#39's current standard/recommended default. V6_WILD/V6_MINI are current experimental/lightweight variants. Everything below the separator is deprecated - kept only for accounts still on an older tier.'
                    ShowHint = True
                    ParentShowHint = False
                    ItemIndex = 0
                    Items.Strings = (
                      'V6'
                      'V6_WILD'
                      'V6_MINI'
                      'V5_5 (deprecated)'
                      'V5 (deprecated)'
                      'V4_5PLUS (deprecated)'
                      'V4_5ALL (deprecated)'
                      'V4_5 (deprecated)'
                      'V4 (deprecated)')
                    Enabled = False
                    TabOrder = 3
                  end
                  object chkSunoAdvanced: TGLCheck
                    Left = 520
                    Top = 45
                    Width = 185
                    Height = 19
                    Hint = 'Off (default): UDAW configures the managed API automatically - just paste in your Suno API key. On: pick the API type and edit base URL/model/callback yourself, e.g. to use a self-hosted proxy.'
                    ShowHint = True
                    ParentShowHint = False
                    Caption = 'Advanced (self-hosted)'
                    TabOrder = 5
                    OnClick = chkSunoAdvancedClick
                  end
                  object lblSunoCallback: TGLLabel
                    Left = 8
                    Top = 78
                    Caption = 'Callback URL'
                  end
                  object edtSunoCallback: TGLEdit
                    Left = 88
                    Top = 74
                    Width = 560
                    Height = 23
                    Enabled = False
                    Hint = 'Managed API: your public HTTPS callback endpoint. UDAW polls for results; it does not host a webhook.'
                    ShowHint = True
                    ParentShowHint = False
                    TabOrder = 4
                  end
                  object lblSunoRefMode: TGLLabel
                    Left = 8
                    Top = 110
                    Caption = 'Ref Audio'
                  end
                  object cboSunoRefMode: TGLCombo
                    Left = 88
                    Top = 106
                    Width = 170
                    Height = 23
                    Hint = 'Uses the recording selected on the Recordings tab. None: ordinary text-to-music generation. Cover: restyle the recording. Extend: continue it from the time below.'
                    ShowHint = True
                    ParentShowHint = False
                    ItemIndex = 0
                    Items.Strings = (
                      'None'
                      'Cover (restyle)'
                      'Extend (continue)')
                    TabOrder = 6
                    OnChange = cboSunoRefModeChange
                  end
                  object lblSunoContinueAt: TGLLabel
                    Left = 270
                    Top = 110
                    Caption = 'Continue at (s)'
                    Visible = False
                  end
                  object edtSunoContinueAt: TGLEdit
                    Left = 360
                    Top = 106
                    Width = 70
                    Height = 23
                    TabOrder = 7
                    Text = '0'
                    Visible = False
                  end
                  object btnSunoGenerate: TGLButton
                    Left = 8
                    Top = 144
                    Width = 85
                    Height = 25
                    Caption = 'Generate'
                    TabOrder = 8
                    OnClick = btnSunoGenerateClick
                  end
                  object btnSunoCancel: TGLButton
                    Left = 100
                    Top = 144
                    Width = 85
                    Height = 25
                    Caption = 'Cancel'
                    TabOrder = 9
                    OnClick = btnSunoCancelClick
                  end
                end
              end
            end
            object pnlAiVoice: TGLPanel
              Left = 0
              Top = 380
              Width = 952
              Height = 40
              Align = alTop
              BevelOuter = bvNone
              TabOrder = 1
              object lblVoiceHint: TGLLabel
                Transparent = True
                Left = 8
                Top = 10
                Width = 500
                Height = 15
                Caption = 'Voice command: records ~4s from the input device, transcribes, then acts or chats'
              end
            end
            object splAiLog: TGLSplitter
              Left = 0
              Top = 420
              Width = 952
              Height = 5
              Cursor = crVSplit
              Align = alTop
              MinSize = 60
            end
            end
          end
        end
      end
      object splTlDock: TGLSplitter
        Left = 0
        Top = 392
        Width = 952
        Height = 5
        Cursor = crVSplit
        Align = alBottom
        MinSize = 120
        ResizeStyle = rsUpdate
        Visible = False
        OnMoved = splTlDockMoved
      end
      object pnlTlVideo: TGLPanel
        Left = 632
        Top = 72
        Width = 320
        Height = 290
        Align = alRight
        BevelOuter = bvNone
        Caption = ''
        Color = clBlack
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clGray
        Font.Height = -12
        Font.Name = 'Segoe UI'
        Font.Style = []
        ParentBackground = False
        ParentFont = False
        ShowCaption = False
        TabOrder = 4
        Visible = False
        OnMouseDown = pnlTlVideoMouseDown
        OnResize = pnlTlVideoResize
        object pnlTlVideoFx: TGLPanel
          Left = 1
          Top = 1
          Width = 318
          Height = 313
          Align = alClient
          BevelOuter = bvNone
          Caption = ''
          Color = clBlack
          ParentBackground = False
          ShowCaption = False
          TabOrder = 0
          Visible = False
          OnMouseDown = pnlTlVideoMouseDown
          object pbTlVideoFx: TGLView
            Left = 0
            Top = 0
            Width = 318
            Height = 313
            Align = alClient
            OnMouseDown = pnlTlVideoMouseDown
            OnPaint = pbTlVideoFxPaint
          end
        end
      end
      object sbTlHorz: TGLScrollBar
        Left = 0
        Top = 387
        Width = 952
        Height = 18
        Align = alBottom
        PageSize = 0
        TabOrder = 2
        OnChange = sbTlHorzChange
      end
      object sbTlVert: TGLScrollBar
        Left = 934
        Top = 36
        Width = 18
        Height = 351
        Align = alRight
        Kind = sbVertical
        PageSize = 0
        TabOrder = 3
        OnChange = sbTlVertChange
      end
      object pbTimeline: TGLView
        Left = 0
        Top = 36
        Width = 952
        Height = 351
        Align = alClient
        OnDragDrop = pbTimelineDragDrop
        OnDragOver = pbTimelineDragOver
        OnDropFiles = pbTimelineDropFiles
        OnMouseDown = pbTimelineMouseDown
        OnMouseLeave = pbTimelineMouseLeave
        OnMouseMove = pbTimelineMouseMove
        OnMouseUp = pbTimelineMouseUp
        OnMouseWheel = pbTimelineMouseWheel
        OnPaint = pbTimelinePaint
      end
      object pnlTlRight: TGLPanel
        Left = 1000
        Top = 98
        Width = 272
        Height = 400
        Align = alRight
        BevelOuter = bvNone
        TabOrder = 8
        object tsTlRight: TGLTabStrip
          CurvedTabs = True
          Left = 8
          Top = 4
          Width = 256
          Height = 28
          Align = alTop
          AlignWithMargins = True
          Margins.Left = 8
          Margins.Top = 4
          Margins.Right = 8
          Margins.Bottom = 6
          Tabs = 'Instruments;Samples;Effects;Tracker;Presets'
          Hints = 'Add tracks (double-click) and edit tracker instruments in the WAV editor (double-click);Audio files from your library folders - drag onto the Timeline to add at the playhead, double-click to edit in the WAV editor;Effects for the selected track - double-click to add one;Tracker modules (.mod .xm .it .mptm .s3m) in the Audio media folder - double-click to load into the Tracker player;Mix presets for the selected track - double-click to apply one'
          OnChange = tsTlRightChange
        end
        object edtTlRightSearch: TGLEdit
          Left = 8
          Top = 38
          Width = 256
          Height = 24
          Align = alTop
          AlignWithMargins = True
          Margins.Left = 8
          Margins.Top = 0
          Margins.Right = 8
          Margins.Bottom = 6
          TabOrder = 0
          TextHint = 'Search instruments and sounds'
          OnChange = edtTlRightSearchChange
        end
        object lblTlRightHint: TGLLabel
          Transparent = True
          Left = 10
          Top = 68
          Width = 200
          Height = 15
          Align = alTop
          AlignWithMargins = True
          Margins.Left = 10
          Margins.Top = 0
          Margins.Right = 8
          Margins.Bottom = 6
          Caption = 'Double-click to add'
        end
        object trTlRight: TGLTree
          Left = 8
          Top = 90
          Width = 256
          Height = 300
          Align = alClient
          AlignWithMargins = True
          Margins.Left = 8
          Margins.Top = 0
          Margins.Right = 8
          Margins.Bottom = 8
          TabOrder = 1
          OnDblClick = trTlRightDblClick
          OnMouseDown = trTlRightMouseDown
          OnExpanding = trTlRightExpanding
        end
      end
      object pnlTlHeaders: TTlHeaderHost
        Left = 0
        Top = 36
        Width = 142
        Height = 300
        OnMouseWheel = pnlTlHeadersMouseWheel
      end
    end
    object tabSettings: TGLPage
      Caption = 'Settings'
      ImageIndex = 16
      object pgcSettings: TGLPageControl
        Left = 0
        Top = 0
        Width = 952
        Height = 531
        Align = alClient
        ActivePage = tabSettingsGeneral
        TabOrder = 0
        OnChange = pgcChange
        object tabSettingsGeneral: TGLPage
          Caption = 'General'
          PopupMenu = pmSettings
          object sbSettings: TGLScrollBox
            Left = 0
            Top = 0
            Width = 952
            Height = 531
            Align = alClient
            TabOrder = 0
            BottomPadding = 200
            object grpStartup: TGLGroup
              Left = 8
              Top = 0
              Width = 920
              Height = 390
              Caption = ' Startup && Audio Engine '
              TabOrder = 0
              object lblSetBackend: TGLLabel
                Transparent = True
                Left = 16
                Top = 27
                Width = 140
                Height = 15
                Caption = 'Audio backend'
              end
              object lblSettingsStatus: TGLLabel
                Transparent = True
                Left = 800
                Top = 27
                Width = 3
                Height = 15
                Anchors = [akTop, akRight]
                Caption = ' '
              end
              object cboSetBackend: TGLCombo
                Left = 164
                Top = 24
                Width = 140
                Height = 23
                TabOrder = 0
              end
              object lblSetRate: TGLLabel
                Transparent = True
                Left = 16
                Top = 59
                Width = 140
                Height = 15
                Caption = 'Sample rate (Hz)'
              end
              object cboSetRate: TGLCombo
                Left = 164
                Top = 56
                Width = 110
                Height = 23
                TabOrder = 1
              end
              object lblSetBuffer: TGLLabel
                Transparent = True
                Left = 16
                Top = 91
                Width = 140
                Height = 15
                Caption = 'Buffer size (frames)'
              end
              object cboSetBuffer: TGLCombo
                Left = 164
                Top = 88
                Width = 110
                Height = 23
                TabOrder = 2
              end
              object lblSetOutCh: TGLLabel
                Transparent = True
                Left = 16
                Top = 123
                Width = 140
                Height = 15
                Caption = 'Output channels'
              end
              object edSetOutCh: TGLEdit
                Left = 164
                Top = 120
                Width = 60
                Height = 23
                NumbersOnly = True
                TabOrder = 3
                Text = '2'
              end
              object lblSetOutDevice: TGLLabel
                Transparent = True
                Left = 240
                Top = 123
                Width = 90
                Height = 15
                Caption = 'Output device'
              end
              object cboSetOutDevice: TGLCombo
                Left = 336
                Top = 120
                Width = 260
                Height = 23
                TabOrder = 16
              end
              object lblSetInCh: TGLLabel
                Transparent = True
                Left = 16
                Top = 155
                Width = 140
                Height = 15
                Caption = 'Input channels'
              end
              object edSetInCh: TGLEdit
                Left = 164
                Top = 152
                Width = 60
                Height = 23
                NumbersOnly = True
                TabOrder = 4
                Text = '2'
              end
              object lblSetInDevice: TGLLabel
                Transparent = True
                Left = 240
                Top = 155
                Width = 90
                Height = 15
                Caption = 'Input device'
              end
              object cboSetInDevice: TGLCombo
                Left = 336
                Top = 152
                Width = 260
                Height = 23
                TabOrder = 11
              end
              object chkSetAutostart: TGLCheck
                Left = 16
                Top = 184
                Width = 400
                Height = 17
                Caption = 'Auto-start audio engine on launch'
                TabOrder = 5
              end
              object chkSetCapture: TGLCheck
                Left = 16
                Top = 216
                Width = 400
                Height = 17
                Caption = 'Enable audio input (capture)'
                TabOrder = 6
              end
              object chkSetExclusive: TGLCheck
                Left = 16
                Top = 248
                Width = 600
                Height = 17
                Caption = 'Exclusive-mode output (applies to the selected backend: WASAPI or DirectSound)'
                TabOrder = 7
              end
              object lblSetLogLevel: TGLLabel
                Transparent = True
                Left = 16
                Top = 283
                Width = 140
                Height = 15
                Caption = 'Log level'
              end
              object cboSetLogLevel: TGLCombo
                Left = 164
                Top = 280
                Width = 110
                Height = 23
                TabOrder = 8
              end
              object lblSetLocale: TGLLabel
                Transparent = True
                Left = 300
                Top = 283
                Width = 60
                Height = 15
                Caption = 'Locale'
              end
              object edSetLocale: TGLEdit
                Left = 366
                Top = 280
                Width = 80
                Height = 23
                TabOrder = 9
                Text = 'en'
              end
              object lblSetTlRefresh: TGLLabel
                Transparent = True
                Left = 470
                Top = 283
                Width = 160
                Height = 15
                Caption = 'Timeline refresh (per second)'
              end
              object cboSetTlRefresh: TGLCombo
                Left = 640
                Top = 280
                Width = 70
                Height = 23
                TabOrder = 14
                OnChange = cboSetTlRefreshChange
              end
              object chkSetTempoAuto: TGLCheck
                Left = 16
                Top = 308
                Width = 430
                Height = 17
                Caption = 'Auto-detect BPM from the first imported audio track (sets Timeline BPM)'
                Checked = True
                TabOrder = 11
              end
              object chkSetShowStart: TGLCheck
                Left = 470
                Top = 308
                Width = 430
                Height = 17
                Hint = 'Show the Project Startup screen (New, Open, recent projects, Help) every time UDAW starts.'
                Caption = 'Show the Project Startup screen on startup'
                Checked = True
                ParentShowHint = False
                ShowHint = True
                TabOrder = 15
              end
              object chkSetTempoResample: TGLCheck
                Left = 16
                Top = 325
                Width = 430
                Height = 17
                Caption = 'Conform clip tempo by resampling (pitch follows tempo)'
                TabOrder = 12
              end
              object chkSetHints: TGLCheck
                Left = 470
                Top = 325
                Width = 430
                Height = 17
                Hint = 'Show a hint bubble when the mouse rests over a control. Applies to the whole application and every project.'
                Caption = 'Show hints when hovering over controls'
                Checked = True
                ParentShowHint = False
                ShowHint = True
                TabOrder = 13
              end
              object lblSetTheme: TGLLabel
                Transparent = True
                Left = 16
                Top = 347
                Width = 140
                Height = 15
                Caption = 'Visual theme'
              end
              object cboSetTheme: TGLCombo
                Left = 164
                Top = 344
                Width = 220
                Height = 23
                TabOrder = 10
                OnChange = cboSetThemeChange
              end
              object lblThemeInfo: TGLLabel
                Transparent = True
                Left = 400
                Top = 347
                Width = 3
                Height = 15
                Caption = ' '
              end
            end
            object grpDirs: TGLGroup
              Left = 8
              Top = 398
              Width = 920
              Height = 366
              Caption = ' Working Directories '
              TabOrder = 1
              object lblDirProjects: TGLLabel
                Transparent = True
                Left = 16
                Top = 27
                Width = 150
                Height = 15
                Caption = 'Projects'
              end
              object edDirProjects: TGLEdit
                Left = 170
                Top = 24
                Width = 650
                Height = 23
                TabOrder = 0
              end
              object btnDirProjects: TGLButton
                Left = 828
                Top = 23
                Width = 80
                Height = 25
                Caption = 'Browse...'
                TabOrder = 1
                Tag = 1
                OnClick = btnSettingsBrowseDirClick
              end
              object lblDirAudioLib: TGLLabel
                Transparent = True
                Left = 16
                Top = 59
                Width = 150
                Height = 15
                Caption = 'Audio / media library'
              end
              object edDirAudioLib: TGLEdit
                Left = 170
                Top = 56
                Width = 650
                Height = 23
                TabOrder = 2
              end
              object btnDirAudioLib: TGLButton
                Left = 828
                Top = 55
                Width = 80
                Height = 25
                Caption = 'Browse...'
                TabOrder = 3
                Tag = 2
                OnClick = btnSettingsBrowseDirClick
              end
              object lblDirSfx: TGLLabel
                Transparent = True
                Left = 16
                Top = 91
                Width = 150
                Height = 15
                Caption = 'Sound effects (SFX)'
              end
              object edDirSfx: TGLEdit
                Left = 170
                Top = 88
                Width = 650
                Height = 23
                TabOrder = 4
              end
              object btnDirSfx: TGLButton
                Left = 828
                Top = 87
                Width = 80
                Height = 25
                Caption = 'Browse...'
                TabOrder = 5
                Tag = 3
                OnClick = btnSettingsBrowseDirClick
              end
              object lblDirExport: TGLLabel
                Transparent = True
                Left = 16
                Top = 123
                Width = 150
                Height = 15
                Caption = 'Export / render output'
              end
              object edDirExport: TGLEdit
                Left = 170
                Top = 120
                Width = 650
                Height = 23
                TabOrder = 6
              end
              object btnDirExport: TGLButton
                Left = 828
                Top = 119
                Width = 80
                Height = 25
                Caption = 'Browse...'
                TabOrder = 7
                Tag = 4
                OnClick = btnSettingsBrowseDirClick
              end
              object lblDirRecordings: TGLLabel
                Transparent = True
                Left = 16
                Top = 155
                Width = 150
                Height = 15
                Caption = 'Recordings'
              end
              object edDirRecordings: TGLEdit
                Left = 170
                Top = 152
                Width = 650
                Height = 23
                TabOrder = 8
              end
              object btnDirRecordings: TGLButton
                Left = 828
                Top = 151
                Width = 80
                Height = 25
                Caption = 'Browse...'
                TabOrder = 9
                Tag = 5
                OnClick = btnSettingsBrowseDirClick
              end
              object lblDirTemp: TGLLabel
                Transparent = True
                Left = 16
                Top = 193
                Width = 150
                Height = 15
                Caption = 'Temporary files'
              end
              object edDirTemp: TGLEdit
                Left = 170
                Top = 190
                Width = 650
                Height = 23
                TabOrder = 10
              end
              object btnDirTemp: TGLButton
                Left = 828
                Top = 189
                Width = 80
                Height = 25
                Caption = 'Browse...'
                TabOrder = 11
                Tag = 6
                OnClick = btnSettingsBrowseDirClick
              end
              object lblDirCache: TGLLabel
                Transparent = True
                Left = 16
                Top = 225
                Width = 150
                Height = 15
                Caption = 'Cache files'
              end
              object edDirCache: TGLEdit
                Left = 170
                Top = 222
                Width = 650
                Height = 23
                TabOrder = 12
              end
              object btnDirCache: TGLButton
                Left = 828
                Top = 221
                Width = 80
                Height = 25
                Caption = 'Browse...'
                TabOrder = 13
                Tag = 7
                OnClick = btnSettingsBrowseDirClick
              end
              object lblDirScripts: TGLLabel
                Transparent = True
                Left = 16
                Top = 257
                Width = 150
                Height = 15
                Caption = 'Scripts (default folder)'
              end
              object edDirScripts: TGLEdit
                Left = 170
                Top = 254
                Width = 650
                Height = 23
                Hint = 'Where Run Python Script opens and where the helper module is written. Empty uses a Scripts folder under the config folder.'
                ShowHint = True
                TabOrder = 14
              end
              object btnDirScripts: TGLButton
                Left = 828
                Top = 253
                Width = 80
                Height = 25
                Caption = 'Browse...'
                TabOrder = 15
                Tag = 8
                OnClick = btnSettingsBrowseDirClick
              end
              object lblDirPresets: TGLLabel
                Transparent = True
                Left = 16
                Top = 293
                Width = 150
                Height = 15
                Caption = 'Presets folder'
              end
              object edDirPresets: TGLEdit
                Left = 170
                Top = 290
                Width = 650
                Height = 23
                Hint = 'Where the effect editors save and load presets. Empty uses the data folder.'
                ShowHint = True
                TabOrder = 16
              end
              object btnDirPresets: TGLButton
                Left = 828
                Top = 289
                Width = 80
                Height = 25
                Caption = 'Browse...'
                TabOrder = 17
                Tag = 9
                OnClick = btnSettingsBrowseDirClick
              end
              object lblDirPlugins: TGLLabel
                Transparent = True
                Left = 16
                Top = 329
                Width = 150
                Height = 15
                Caption = 'Python plug-ins folder'
              end
              object edDirPlugins: TGLEdit
                Left = 170
                Top = 326
                Width = 650
                Height = 23
                Hint = 'Where your Python plug-ins live and where the Plugins menu looks. The default is the plugins folder next to UDAW.exe.'
                ShowHint = True
                TabOrder = 18
              end
              object btnDirPlugins: TGLButton
                Left = 828
                Top = 325
                Width = 80
                Height = 25
                Caption = 'Browse...'
                TabOrder = 19
                Tag = 10
                OnClick = btnSettingsBrowseDirClick
              end
            end
            object grpSystemPaths: TGLGroup
              Left = 8
              Top = 772
              Width = 920
              Height = 170
              Caption = ' System Locations (read-only) '
              TabOrder = 2
              object lblSysConfig: TGLLabel
                Transparent = True
                Left = 16
                Top = 25
                Width = 150
                Height = 15
                Caption = 'Config folder'
              end
              object edSysConfig: TGLEdit
                Left = 170
                Top = 22
                Width = 738
                Height = 19
                ReadOnly = True
                TabOrder = 0
              end
              object lblSysData: TGLLabel
                Transparent = True
                Left = 16
                Top = 45
                Width = 150
                Height = 15
                Caption = 'Data folder'
              end
              object edSysData: TGLEdit
                Left = 170
                Top = 42
                Width = 738
                Height = 19
                ReadOnly = True
                TabOrder = 1
              end
              object lblSysCache: TGLLabel
                Transparent = True
                Left = 16
                Top = 65
                Width = 150
                Height = 15
                Caption = 'Cache folder'
              end
              object edSysCache: TGLEdit
                Left = 170
                Top = 62
                Width = 738
                Height = 19
                ReadOnly = True
                TabOrder = 2
              end
              object lblSysLogs: TGLLabel
                Transparent = True
                Left = 16
                Top = 85
                Width = 150
                Height = 15
                Caption = 'Log folder'
              end
              object edSysLogs: TGLEdit
                Left = 170
                Top = 82
                Width = 738
                Height = 19
                ReadOnly = True
                TabOrder = 3
              end
              object lblSysTemp: TGLLabel
                Transparent = True
                Left = 16
                Top = 105
                Width = 150
                Height = 15
                Caption = 'Temp folder'
              end
              object edSysTemp: TGLEdit
                Left = 170
                Top = 102
                Width = 738
                Height = 19
                ReadOnly = True
                TabOrder = 4
              end
              object lblSysCfgFile: TGLLabel
                Transparent = True
                Left = 16
                Top = 125
                Width = 150
                Height = 15
                Caption = 'Config file'
              end
              object edSysCfgFile: TGLEdit
                Left = 170
                Top = 122
                Width = 738
                Height = 19
                ReadOnly = True
                TabOrder = 5
              end
              object lblSysExe: TGLLabel
                Transparent = True
                Left = 16
                Top = 145
                Width = 150
                Height = 15
                Caption = 'Executable'
              end
              object edSysExe: TGLEdit
                Left = 170
                Top = 142
                Width = 738
                Height = 19
                ReadOnly = True
                TabOrder = 6
              end
            end
            object grpColorTheme: TGLGroup
              Left = 8
              Top = 950
              Width = 920
              Height = 90
              Caption = ' Color Theme'
              TabOrder = 3
              object lblColorTheme: TGLLabel
                Transparent = True
                Left = 16
                Top = 27
                Width = 140
                Height = 15
                Caption = 'Theme'
              end
              object cboColorTheme: TGLCombo
                Left = 164
                Top = 24
                Width = 220
                Height = 23
                TabOrder = 0
                OnChange = cboColorThemeChange
              end
              object btnColorThemeSave: TGLButton
                Left = 16
                Top = 56
                Width = 100
                Height = 25
                Caption = 'Save copy...'
                TabOrder = 1
                OnClick = btnColorThemeSaveClick
              end
              object btnColorThemeReset: TGLButton
                Left = 122
                Top = 56
                Width = 80
                Height = 25
                Caption = 'Reset'
                TabOrder = 2
                OnClick = btnColorThemeResetClick
              end
              object btnColorThemeExport: TGLButton
                Left = 208
                Top = 56
                Width = 80
                Height = 25
                Caption = 'Export...'
                TabOrder = 3
                OnClick = btnColorThemeExportClick
              end
              object btnColorThemeImport: TGLButton
                Left = 294
                Top = 56
                Width = 80
                Height = 25
                Caption = 'Import...'
                TabOrder = 4
                OnClick = btnColorThemeImportClick
              end
              object lblColorThemeStatus: TGLLabel
                Transparent = True
                Left = 400
                Top = 62
                Width = 3
                Height = 15
                Caption = ' '
              end
            end
            object grpMidiDevices: TGLGroup
              Left = 8
              Top = 1048
              Width = 920
              Height = 110
              Caption = ' MIDI Devices'
              TabOrder = 4
              object lblSetMidiIn: TGLLabel
                Transparent = True
                Left = 16
                Top = 27
                Width = 150
                Height = 15
                Caption = 'Input device'
              end
              object lblSetMidiOut: TGLLabel
                Transparent = True
                Left = 16
                Top = 66
                Width = 150
                Height = 15
                Caption = 'Output device'
              end
              object cboSetMidiInDevice: TGLCombo
                Left = 164
                Top = 24
                Width = 340
                Height = 23
                TabOrder = 0
                OnChange = cboSetMidiInDeviceChange
              end
              object cboSetMidiOutDevice: TGLCombo
                Left = 164
                Top = 63
                Width = 340
                Height = 23
                TabOrder = 1
                OnChange = cboSetMidiOutDeviceChange
              end
              object btnSetMidiRefresh: TGLButton
                Left = 520
                Top = 24
                Width = 100
                Height = 25
                Caption = 'Refresh list'
                TabOrder = 2
                OnClick = btnSetMidiRefreshClick
              end
              object btnSetMidiPanic: TGLButton
                Left = 520
                Top = 63
                Width = 100
                Height = 25
                Caption = 'MIDI Panic'
                TabOrder = 3
                OnClick = btnSetMidiPanicClick
              end
              object lblSetMidiStatus: TGLLabel
                Transparent = True
                Left = 640
                Top = 68
                Width = 3
                Height = 15
                Caption = ' '
              end
            end
            object grpExport: TGLGroup
              Left = 8
              Top = 1130
              Width = 920
              Height = 150
              Caption = ' Export (saved with the project) '
              TabOrder = 5
              object lblExpBitrate: TGLLabel
                Transparent = True
                Left = 16
                Top = 27
                Width = 140
                Height = 15
                Caption = 'Video quality (bitrate)'
              end
              object cboExpBitrate: TGLCombo
                Left = 164
                Top = 24
                Width = 160
                Height = 23
                TabOrder = 0
                OnChange = cboExportChange
              end
              object lblExpWidth: TGLLabel
                Transparent = True
                Left = 16
                Top = 59
                Width = 140
                Height = 15
                Caption = 'Video size (max width)'
              end
              object cboExpWidth: TGLCombo
                Left = 164
                Top = 56
                Width = 160
                Height = 23
                TabOrder = 1
                OnChange = cboExportChange
              end
              object lblExpAuthor: TGLLabel
                Transparent = True
                Left = 16
                Top = 91
                Width = 140
                Height = 15
                Caption = 'Author (embedded)'
              end
              object edExpAuthor: TGLEdit
                Left = 164
                Top = 88
                Width = 340
                Height = 23
                TabOrder = 2
                OnExit = edExpAuthorExit
              end
              object lblExpAudio: TGLLabel
                Transparent = True
                Left = 360
                Top = 27
                Width = 140
                Height = 15
                Caption = 'Audio quality (bitrate)'
              end
              object cboExpAudio: TGLCombo
                Left = 508
                Top = 24
                Width = 160
                Height = 23
                TabOrder = 3
                OnChange = cboExportChange
              end
              object lblExpNote: TGLLabel
                Transparent = True
                Left = 16
                Top = 120
                Width = 880
                Height = 15
                Caption = 'Video settings apply to MP4 / MKV exports; audio quality applies to MP3, MP4, M4A and MKV. The author name is written into the header of every exported file.'
              end
            end
          end
        end
        object tabRegistration: TGLPage
          Caption = 'Registration'
          object grpRegStatus: TGLGroup
            Left = 8
            Top = 8
            Width = 920
            Height = 88
            Caption = ' Registration status '
            TabOrder = 0
            object lblRegStatus: TGLLabel
              Left = 16
              Top = 22
              Width = 122
              Height = 25
              Caption = 'Unregistered'
              Font.Charset = DEFAULT_CHARSET
              Font.Color = clWindowText
              Font.Height = -19
              Font.Name = 'Segoe UI'
              Font.Style = [fsBold]
              ParentFont = False
              Transparent = True
            end
            object lblRegDetail: TGLLabel
              Left = 16
              Top = 56
              Width = 888
              Height = 15
              Anchors = [akLeft, akTop, akRight]
              AutoSize = False
              Caption = ' '
              Transparent = True
            end
          end
          object grpRegCredentials: TGLGroup
            Left = 8
            Top = 104
            Width = 920
            Height = 216
            Caption = ' Account credentials (from ultimanium.com) '
            TabOrder = 1
            object lblRegUsername: TGLLabel
              Left = 16
              Top = 30
              Width = 100
              Height = 15
              Caption = 'Username'
              Transparent = True
            end
            object edtRegUsername: TGLEdit
              Left = 164
              Top = 27
              Width = 300
              Height = 23
              TabOrder = 0
            end
            object lblRegPassword: TGLLabel
              Left = 16
              Top = 62
              Width = 100
              Height = 15
              Caption = 'Password'
              Transparent = True
            end
            object edtRegPassword: TGLEdit
              Left = 164
              Top = 59
              Width = 300
              Height = 23
              PasswordChar = '*'
              TabOrder = 1
            end
            object lblRegSerial: TGLLabel
              Left = 16
              Top = 94
              Width = 100
              Height = 15
              Caption = 'Serial number key'
              Transparent = True
            end
            object edtRegSerial: TGLEdit
              Left = 164
              Top = 91
              Width = 300
              Height = 23
              TabOrder = 2
            end
            object btnRegRegister: TGLButton
              Left = 164
              Top = 128
              Width = 120
              Height = 27
              Caption = 'Register'
              Default = True
              TabOrder = 3
              OnClick = btnRegRegisterClick
            end
            object btnRegUnregister: TGLButton
              Left = 292
              Top = 128
              Width = 120
              Height = 27
              Caption = 'Unregister'
              TabOrder = 4
              OnClick = btnRegUnregisterClick
            end
            object lblRegHint: TGLLabel
              Left = 16
              Top = 168
              Width = 888
              Height = 36
              Anchors = [akLeft, akTop, akRight]
              AutoSize = False
              Caption =
                'Your username, password and serial number key are obtained from ' +
                'your account at ultimanium.com. Until registered, UDAW runs with' +
                ' full functionality except exporting of any kind and any use of ' +
                'AI, which are disabled.'
              Transparent = True
              WordWrap = True
            end
          end
          object grpRegUpdate: TGLGroup
            Left = 8
            Top = 328
            Width = 920
            Height = 120
            Caption = ' Updates '
            TabOrder = 2
            object lblRegVersion: TGLLabel
              Left = 16
              Top = 30
              Width = 888
              Height = 15
              Anchors = [akLeft, akTop, akRight]
              AutoSize = False
              Caption = 'Installed version:'
              Transparent = True
            end
            object lblRegUpdateStatus: TGLLabel
              Left = 16
              Top = 54
              Width = 888
              Height = 15
              Anchors = [akLeft, akTop, akRight]
              AutoSize = False
              Caption = ' '
              Transparent = True
            end
            object btnRegCheckUpdate: TGLButton
              Left = 16
              Top = 80
              Width = 150
              Height = 27
              Caption = 'Check for updates'
              TabOrder = 0
              OnClick = btnRegCheckUpdateClick
            end
            object btnRegInstallUpdate: TGLButton
              Left = 174
              Top = 80
              Width = 190
              Height = 27
              Caption = 'Download && install update'
              Enabled = False
              TabOrder = 1
              OnClick = btnRegInstallUpdateClick
            end
          end
        end
        object tabColors: TGLPage
          Caption = 'Colours'
          object pnlColorsTop: TGLPanel
            Left = 0
            Top = 0
            Width = 952
            Height = 40
            Align = alTop
            BevelOuter = bvNone
            TabOrder = 0
            object lblColorsTitle: TGLLabel
              Transparent = True
              Left = 8
              Top = 13
              Width = 400
              Height = 15
              Caption = 'Editing theme colors'
            end
          end
          object lbColorSwatches: TGLList
            Align = alLeft
            AlignWithMargins = True
            Margins.Left = 8
            Margins.Top = 8
            Margins.Right = 12
            Margins.Bottom = 8
            Left = 8
            Top = 48
            Width = 280
            Height = 480
            ItemHeight = 15
            TabOrder = 1
            OnClick = lbColorSwatchesClick
          end
          object pbColorPreview: TGLView
            Left = 300
            Top = 48
            Width = 140
            Height = 40
            OnPaint = pbColorPreviewPaint
          end
          object btnColorPick: TGLButton
            Left = 300
            Top = 96
            Width = 140
            Height = 25
            Caption = 'Change Color...'
            TabOrder = 3
            OnClick = btnColorPickClick
          end
          object btnColorsSave: TGLButton
            Left = 300
            Top = 130
            Width = 140
            Height = 25
            Caption = 'Save to Theme'
            TabOrder = 4
            OnClick = btnColorsSaveClick
          end
          object btnColorsResetTheme: TGLButton
            Left = 300
            Top = 164
            Width = 140
            Height = 25
            Caption = 'Reset Theme Colors'
            TabOrder = 5
            OnClick = btnColorsResetThemeClick
          end
          object lblColorsStatus: TGLLabel
            Transparent = True
            Left = 300
            Top = 200
            Width = 3
            Height = 15
            Caption = ' '
          end
          object lblColorsHint: TGLLabel
            Transparent = True
            Left = 300
            Top = 228
            Width = 380
            Height = 75
            WordWrap = True
            Caption =
              'Changes apply immediately across the app (waveforms, meters, p' +
              'iano roll, log levels, etc). "Save to Theme" keeps them the ne' +
              'xt time UDAW starts; "Reset" reverts this theme to its shipped' +
              ' colors. Pick which theme to edit on the Settings tab.'
          end
          object lblFadeDisplay: TGLLabel
            Left = 300
            Top = 322
            Caption = 'Fade representation (all timeline clips)'
          end
          object cboFadeDisplay: TGLCombo
            Left = 300
            Top = 344
            Width = 270
            Height = 23
            TabOrder = 6
            ItemIndex = 0
            Items.Strings = (
              'Coloured areas'
              'Graphical curves and handles'
              'Coloured areas with curves')
            OnChange = cboFadeDisplayChange
          end
        end
        object tabGlDisplay: TGLPage
          Caption = 'OpenGL'
          object grpGlDisplay: TGLGroup
            Left = 8
            Top = 8
            Width = 920
            Height = 296
            Caption = ' Screen mode && frame rate '
            TabOrder = 0
            object lblGlMode: TGLLabel
              Transparent = True
              Left = 16
              Top = 30
              Width = 190
              Height = 15
              Caption = 'Screen mode'
            end
            object cboGlMode: TGLCombo
              Left = 220
              Top = 27
              Width = 280
              Height = 23
              Hint = 'Windowed is the normal window. Borderless full screen covers the monitor without changing its mode. Exclusive full screen switches the monitor itself to the resolution and refresh rate below and restores it when you go back or UDAW closes.'
              ParentShowHint = False
              ShowHint = True
              TabOrder = 0
              OnChange = cboGlModeChange
            end
            object lblGlMonitor: TGLLabel
              Transparent = True
              Left = 16
              Top = 62
              Width = 190
              Height = 15
              Caption = 'Monitor'
            end
            object cboGlMonitor: TGLCombo
              Left = 220
              Top = 59
              Width = 280
              Height = 23
              Hint = 'The monitor the full screen window goes to'
              ParentShowHint = False
              ShowHint = True
              TabOrder = 1
              OnChange = cboGlMonitorChange
            end
            object lblGlRes: TGLLabel
              Transparent = True
              Left = 16
              Top = 94
              Width = 190
              Height = 15
              Caption = 'Resolution and refresh rate'
            end
            object cboGlRes: TGLCombo
              Left = 220
              Top = 91
              Width = 280
              Height = 23
              Hint = 'The modes this monitor offers. Used by Exclusive full screen; borderless full screen keeps the desktop mode.'
              ParentShowHint = False
              ShowHint = True
              TabOrder = 2
            end
            object chkGlFps: TGLCheck
              Left = 16
              Top = 132
              Width = 620
              Height = 17
              Hint = 'Shows the render rate (frames per second the OpenGL surfaces are drawn at) in the top right corner of the window'
              Caption = 'Show frames per second in the top right corner'
              ParentShowHint = False
              ShowHint = True
              TabOrder = 3
            end
            object lblGlFpsWhen: TGLLabel
              Transparent = True
              Left = 16
              Top = 164
              Width = 190
              Height = 15
              Caption = 'Show the frame rate'
            end
            object cboGlFpsWhen: TGLCombo
              Left = 220
              Top = 161
              Width = 280
              Height = 23
              Hint = 'Always, only while in full screen, or only while in a window'
              ParentShowHint = False
              ShowHint = True
              TabOrder = 4
            end
            object btnGlApply: TGLButton
              Left = 16
              Top = 204
              Width = 150
              Height = 30
              Hint = 'Apply these choices now and remember them for the next start'
              Caption = 'Apply'
              ParentShowHint = False
              ShowHint = True
              TabOrder = 5
              OnClick = btnGlApplyClick
            end
            object lblGlStatus: TGLLabel
              Transparent = True
              Left = 180
              Top = 211
              Width = 720
              Height = 15
              Caption = ' '
            end
            object lblGlNote: TGLLabel
              Transparent = True
              Left = 16
              Top = 248
              Width = 880
              Height = 40
              AutoSize = False
              WordWrap = True
              Caption = 'The frame rate is the number of times per second the busiest OpenGL surface is redrawn; a surface only redraws when something on it changes, so it reads low while nothing moves. Exclusive full screen is undone by Windowed at any time, and Windows restores the monitor by itself if UDAW ends.'
            end
          end
          object grpGlInfo: TGLGroup
            Left = 8
            Top = 312
            Width = 920
            Height = 120
            Caption = ' This computer''s OpenGL '
            TabOrder = 1
            object lblGlRenderer: TGLLabel
              Transparent = True
              Left = 16
              Top = 28
              Width = 880
              Height = 15
              Caption = ' '
            end
            object lblGlVersion: TGLLabel
              Transparent = True
              Left = 16
              Top = 52
              Width = 880
              Height = 15
              Caption = ' '
            end
            object lblGlMemory: TGLLabel
              Transparent = True
              Left = 16
              Top = 76
              Width = 880
              Height = 15
              Caption = ' '
            end
          end
        end
        object tabKeyHooks: TGLPage
          Caption = 'Key Hooks'
          object pnlKeyHooksFoot: TGLPanel
            Left = 0
            Top = 0
            Width = 100
            Height = 38
            Align = alBottom
            BevelOuter = bvNone
            TabOrder = 9
            object btnKeyHookAssign: TGLButton
              Left = 8
              Top = 6
              Width = 160
              Height = 25
              Caption = 'Assign New Key...'
              TabOrder = 1
              OnClick = btnKeyHookAssignClick
            end
            object btnKeyHookSave: TGLButton
              Left = 176
              Top = 6
              Width = 120
              Height = 25
              Caption = 'Save'
              TabOrder = 2
              OnClick = btnKeyHookSaveClick
            end
            object btnKeyHookRestore: TGLButton
              Left = 304
              Top = 6
              Width = 160
              Height = 25
              Caption = 'Restore Defaults'
              TabOrder = 3
              OnClick = btnKeyHookRestoreClick
            end
            object btnKeyHookToggle: TGLButton
              Left = 472
              Top = 6
              Width = 160
              Height = 25
              Caption = 'Enable / Disable'
              TabOrder = 4
              OnClick = btnKeyHookToggleClick
            end
          end
          object lblKeyHooksHint: TGLLabel
            Align = alTop
            AlignWithMargins = True
            Margins.Left = 8
            Margins.Top = 8
            Margins.Right = 8
            Margins.Bottom = 7
            Transparent = True
            Left = 8
            Top = 8
            Width = 920
            Height = 15
            Caption = 'All keyboard shortcuts currently assigned in UDAW. Select a global row and click Assign New Key to rebind it.'
          end
          object lvKeyHooks: TGLListView
            Align = alClient
            AlignWithMargins = True
            Margins.Left = 8
            Margins.Top = 0
            Margins.Right = 8
            Margins.Bottom = 0
            Left = 8
            Top = 30
            Width = 920
            Height = 420
            Columns = <
              item
                Caption = 'Action'
                Width = 220
              end
              item
                Caption = 'Shortcut'
                Width = 180
              end
              item
                Caption = 'Context'
                Width = 300
              end
              item
                Caption = 'Description'
                Width = 560
              end
              item
                Caption = 'Status'
                Width = 160
              end>
            GridLines = True
            ReadOnly = True
            RowSelect = True
            TabOrder = 0
            ViewStyle = vsReport
          end
        end
        object tabSettingsProject: TGLPage
          Caption = 'Project'
          PopupMenu = pmProject
          object pnlProjectTop: TGLPanel
            Left = 0
            Top = 0
            Width = 952
            Height = 168
            Align = alTop
            BevelOuter = bvNone
            TabOrder = 0
            object lblProjectFile: TGLLabel
              Transparent = True
              Left = 8
              Top = 8
              Width = 300
              Height = 15
              Caption = '(untitled - not saved)'
            end
            object lblProjectName: TGLLabel
              Transparent = True
              Left = 8
              Top = 34
              Width = 31
              Height = 15
              Caption = 'Name'
            end
            object lblProjectTempo: TGLLabel
              Transparent = True
              Left = 196
              Top = 34
              Width = 33
              Height = 15
              Caption = 'Tempo'
            end
            object lblProjectTimeSig: TGLLabel
              Transparent = True
              Left = 264
              Top = 34
              Width = 47
              Height = 15
              Caption = 'Time sig.'
            end
            object lblTimeSigSlash: TGLLabel
              Transparent = True
              Left = 298
              Top = 53
              Width = 8
              Height = 15
              Caption = '/'
            end
            object lblProjectSampleRate: TGLLabel
              Transparent = True
              Left = 348
              Top = 34
              Width = 60
              Height = 15
              Caption = 'Sample rate'
            end
            object lblProjectChannels: TGLLabel
              Transparent = True
              Left = 446
              Top = 34
              Width = 45
              Height = 15
              Caption = 'Channels'
            end
            object lblProjectAuthor: TGLLabel
              Transparent = True
              Left = 8
              Top = 76
              Width = 74
              Height = 15
              Caption = 'Author'#39's name'
            end
            object lblAutosave: TGLLabel
              Transparent = True
              Left = 8
              Top = 116
              Width = 44
              Height = 15
              Caption = 'Autosave'
            end
            object edtProjectName: TGLEdit
              Left = 8
              Top = 50
              Width = 180
              Height = 23
              TabOrder = 4
              OnExit = edtProjectNameExit
            end
            object edtProjectAuthor: TGLEdit
              Left = 8
              Top = 92
              Width = 180
              Height = 23
              TabOrder = 20
              OnExit = edtProjectAuthorExit
            end
            object edtProjectTempo: TGLEdit
              Left = 196
              Top = 50
              Width = 60
              Height = 23
              TabOrder = 5
            end
            object edtTimeSigNum: TGLEdit
              Left = 264
              Top = 50
              Width = 32
              Height = 23
              TabOrder = 6
            end
            object edtTimeSigDen: TGLEdit
              Left = 308
              Top = 50
              Width = 32
              Height = 23
              TabOrder = 7
            end
            object cboProjectSampleRate: TGLCombo
              Left = 348
              Top = 50
              Width = 90
              Height = 23
              TabOrder = 8
            end
            object edtProjectChannels: TGLEdit
              Left = 446
              Top = 50
              Width = 40
              Height = 23
              TabOrder = 9
            end
            object cboAutosaveInterval: TGLCombo
              Left = 8
              Top = 132
              Width = 140
              Height = 23
              TabOrder = 10
              OnChange = cboAutosaveIntervalChange
            end
          end
          object pnlProjectReadout: TGLPanel
            Left = 0
            Top = 168
            Width = 952
            Height = 361
            Align = alClient
            BevelOuter = bvNone
            TabOrder = 1
          end
        end
        object tabSettingsDiagnostics: TGLPage
          Caption = 'Diagnostics'
          object pgcDiagnostics: TGLPageControl
            Left = 0
            Top = 0
            Width = 936
            Height = 475
            Align = alClient
            ActivePage = tabSystem
            TabOrder = 0
            OnChange = pgcChange
            object tabSystem: TGLPage
              Caption = 'System'
              object pnlSysTop: TGLPanel
                Left = 0
                Top = 0
                Width = 936
                Height = 36
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                object lblSysFilter: TGLLabel
                  Transparent = True
                  Left = 10
                  Top = 11
                  Width = 34
                  Height = 15
                  Caption = 'Filter'
                end
                object edtSysFilter: TGLEdit
                  Left = 52
                  Top = 6
                  Width = 260
                  Height = 24
                  Hint = 'Show only the rows whose name or value contains this text (memory, GPU, driver, DPI ...)'
                  ParentShowHint = False
                  ShowHint = True
                  TabOrder = 0
                  OnChange = edtSysFilterChange
                end
                object btnSysRefresh: TGLButton
                  Left = 330
                  Top = 5
                  Width = 96
                  Height = 26
                  Hint = 'Read everything again: memory, GPU, processes and modules change while UDAW runs'
                  Caption = 'Refresh'
                  ParentShowHint = False
                  ShowHint = True
                  TabOrder = 1
                  OnClick = btnSysRefreshClick
                end
                object btnSysCopy: TGLButton
                  Left = 434
                  Top = 5
                  Width = 130
                  Height = 26
                  Hint = 'Copy the whole report to the clipboard, ready to paste into a bug report'
                  Caption = 'Copy report'
                  ParentShowHint = False
                  ShowHint = True
                  TabOrder = 2
                  OnClick = btnSysCopyClick
                end
                object lblSysCount: TGLLabel
                  Transparent = True
                  Left = 580
                  Top = 11
                  Width = 340
                  Height = 15
                  Caption = ' '
                end
              end
              object ivSystem: TGLInfoView
                Left = 0
                Top = 36
                Width = 936
                Height = 439
                Align = alClient
                TabOrder = 1
              end
            end
            object tabJobs: TGLPage
              Caption = 'Jobs'
              ImageIndex = 2
              object lvJobs: TGLListView
                Left = 0
                Top = 0
                Width = 952
                Height = 490
                Align = alClient
                PopupMenu = pmJobs
                Columns = <
                  item
                    Caption = 'Id'
                    Width = 50
                  end
                  item
                    Caption = 'Title'
                    Width = 260
                  end
                  item
                    Caption = 'Status'
                    Width = 110
                  end
                  item
                    Caption = 'Progress'
                    Width = 420
                  end>
                ReadOnly = True
                RowSelect = True
                TabOrder = 0
                ViewStyle = vsReport
              end
            end
            object tabAudio: TGLPage
              Caption = 'Audio'
              ImageIndex = 3
              object pnlAudioMeters: TGLPanel
                Left = 0
                Top = 0
                Width = 952
                Height = 64
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                object lblOutL: TGLLabel
                  Transparent = True
                  Left = 8
                  Top = 10
                  Width = 30
                  Height = 15
                  Caption = 'Out L'
                end
                object lblOutR: TGLLabel
                  Transparent = True
                  Left = 8
                  Top = 36
                  Width = 31
                  Height = 15
                  Caption = 'Out R'
                end
                object pbOutL: TGLProgress
                  Left = 48
                  Top = 8
                  Width = 500
                  Height = 18
                  Max = 1000
                  TabOrder = 0
                end
                object pbOutR: TGLProgress
                  Left = 48
                  Top = 34
                  Width = 500
                  Height = 18
                  Max = 1000
                  TabOrder = 1
                end
                object lblAudioState: TGLLabel
                  Transparent = True
                  Left = 564
                  Top = 10
                  Width = 3
                  Height = 15
                  Caption = ' '
                end
              end
            end
            object tabDSP: TGLPage
              Caption = 'DSP'
              ImageIndex = 4
              object pnlDspTop: TGLPanel
                Left = 0
                Top = 0
                Width = 952
                Height = 72
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                object lblDspSignal: TGLLabel
                  Transparent = True
                  Left = 8
                  Top = 6
                  Width = 32
                  Height = 15
                  Caption = 'Signal'
                end
                object lblDspFilter: TGLLabel
                  Transparent = True
                  Left = 200
                  Top = 6
                  Width = 26
                  Height = 15
                  Caption = 'Filter'
                end
                object lblDspWindow: TGLLabel
                  Transparent = True
                  Left = 452
                  Top = 6
                  Width = 62
                  Height = 15
                  Caption = 'FFT window'
                end
                object cboDspSignal: TGLCombo
                  Left = 8
                  Top = 22
                  Width = 180
                  Height = 23
                  TabOrder = 0
                end
                object cboDspFilter: TGLCombo
                  Left = 200
                  Top = 22
                  Width = 240
                  Height = 23
                  TabOrder = 1
                end
                object cboDspWindow: TGLCombo
                  Left = 452
                  Top = 22
                  Width = 150
                  Height = 23
                  TabOrder = 2
                end
                object chkDspLive: TGLCheck
                  Left = 736
                  Top = 24
                  Width = 90
                  Height = 17
                  Caption = 'Live'
                  TabOrder = 4
                  OnClick = chkDspLiveClick
                end
              end
              object pnlDspReadout: TGLPanel
                Left = 0
                Top = 381
                Width = 952
                Height = 150
                Align = alBottom
                BevelOuter = bvNone
                TabOrder = 1
              end
              object pbSpectrum: TGLView
                Left = 0
                Top = 72
                Width = 952
                Height = 309
                Align = alClient
                PopupMenu = pmDsp
                OnPaint = pbSpectrumPaint
                ExplicitLeft = 240
                ExplicitTop = 168
              end
            end
            object tabGraph: TGLPage
              Caption = 'Graph'
              ImageIndex = 5
              object pnlGraphTop: TGLPanel
                Left = 0
                Top = 0
                Width = 952
                Height = 72
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                object lblGraphPreset: TGLLabel
                  Transparent = True
                  Left = 8
                  Top = 6
                  Width = 34
                  Height = 15
                  Caption = 'Preset'
                end
                object cboGraphPreset: TGLCombo
                  Left = 8
                  Top = 22
                  Width = 420
                  Height = 23
                  TabOrder = 0
                end
                object chkGraphLive: TGLCheck
                  Left = 712
                  Top = 24
                  Width = 90
                  Height = 17
                  Caption = 'Live'
                  TabOrder = 3
                  OnClick = chkGraphLiveClick
                end
              end
              object pnlGraphReadout: TGLPanel
                Left = 0
                Top = 361
                Width = 952
                Height = 170
                Align = alBottom
                BevelOuter = bvNone
                TabOrder = 1
              end
              object pbGraph: TGLView
                Left = 0
                Top = 72
                Width = 952
                Height = 289
                Align = alClient
                PopupMenu = pmGraph
                OnPaint = pbGraphPaint
              end
            end
            object tabWav: TGLPage
              Caption = 'Supported SFX'
              ImageIndex = 7
              object pnlWavTop: TGLPanel
                Left = 0
                Top = 0
                Width = 952
                Height = 80
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                object lblWavFormat: TGLLabel
                  Transparent = True
                  Left = 8
                  Top = 46
                  Width = 68
                  Height = 15
                  Caption = 'Write format'
                end
                object chkWavLoop: TGLCheck
                  Left = 8
                  Top = 14
                  Width = 60
                  Height = 17
                  Caption = 'Loop'
                  TabOrder = 0
                end
                object cboWavFormat: TGLCombo
                  Left = 84
                  Top = 42
                  Width = 170
                  Height = 23
                  TabOrder = 1
                end
              end
            end
            object tabSecure: TGLPage
              Caption = 'Secure Storage'
              ImageIndex = 10
              PopupMenu = pmSecure
              object lblSecureProvider: TGLLabel
                Transparent = True
                Left = 12
                Top = 12
                Width = 90
                Height = 15
                Caption = 'Provider: (none)'
              end
              object lblKey: TGLLabel
                Transparent = True
                Left = 12
                Top = 48
                Width = 22
                Height = 15
                Caption = 'Key'
              end
              object lblValue: TGLLabel
                Transparent = True
                Left = 12
                Top = 80
                Width = 30
                Height = 15
                Caption = 'Value'
              end
              object edtKey: TGLEdit
                Left = 64
                Top = 44
                Width = 300
                Height = 23
                TabOrder = 0
                Text = 'openai.api_key'
              end
              object edtValue: TGLEdit
                Left = 64
                Top = 76
                Width = 300
                Height = 23
                TabOrder = 1
              end
              object btnSecStore: TGLButton
                Left = 380
                Top = 43
                Width = 90
                Height = 25
                Hint = 'Encrypt the value with the OS user key (DPAPI) and save it under the secret name.'
                Caption = 'Store'
                ParentShowHint = False
                ShowHint = True
                TabOrder = 2
                OnClick = btnSecretSetClick
              end
              object btnSecRead: TGLButton
                Left = 476
                Top = 43
                Width = 90
                Height = 25
                Hint = 'Decrypt and show the secret. The value is masked unless Show values is ticked.'
                Caption = 'Read'
                ParentShowHint = False
                ShowHint = True
                TabOrder = 3
                OnClick = btnSecretGetClick
              end
              object btnSecDelete: TGLButton
                Left = 572
                Top = 43
                Width = 90
                Height = 25
                Hint = 'Remove the secret from the store.'
                Caption = 'Delete'
                ParentShowHint = False
                ShowHint = True
                TabOrder = 4
                OnClick = btnSecretDeleteClick
              end
              object chkSecReveal: TGLCheck
                Left = 380
                Top = 79
                Width = 200
                Height = 17
                Hint = 'Display decrypted values in the log instead of masking them.'
                Caption = 'Show values'
                ParentShowHint = False
                ShowHint = True
                TabOrder = 6
              end
              object btnSecSeal: TGLButton
                Left = 12
                Top = 116
                Width = 200
                Height = 25
                Hint = 'Encrypt a fingerprint of the open project (name, tempo, tracks, clips, instruments) into the secure store.'
                Caption = 'Seal current project'
                ParentShowHint = False
                ShowHint = True
                TabOrder = 7
                OnClick = btnSecSealClick
              end
              object btnSecVerify: TGLButton
                Left = 220
                Top = 116
                Width = 200
                Height = 25
                Hint = 'Decrypt the stored fingerprint and report whether the project changed since it was sealed.'
                Caption = 'Verify current project'
                ParentShowHint = False
                ShowHint = True
                TabOrder = 8
                OnClick = btnSecVerifyClick
              end
              object btnSecProbe: TGLButton
                Left = 428
                Top = 116
                Width = 200
                Height = 25
                Hint = 'Store, read back and delete a test value to prove the secure store works on this machine.'
                Caption = 'Round-trip self-test'
                ParentShowHint = False
                ShowHint = True
                TabOrder = 9
                OnClick = btnSecProbeClick
              end
            end
            object tabMP3: TGLPage
              Caption = 'MP3'
              ImageIndex = 13
              object pnlMp3Top: TGLPanel
                Left = 0
                Top = 0
                Width = 952
                Height = 36
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                object lblMp3Bitrate: TGLLabel
                  Transparent = True
                  Left = 8
                  Top = 10
                  Width = 96
                  Height = 15
                  Caption = 'Export kbps (CBR)'
                end
                object cboMp3Bitrate: TGLCombo
                  Left = 116
                  Top = 6
                  Width = 90
                  Height = 23
                  TabOrder = 0
                end
              end
            end
            object tabMP4: TGLPage
              Caption = 'MP4'
              ImageIndex = 14
              object pnlMp4Top: TGLPanel
                Left = 0
                Top = 0
                Width = 952
                Height = 80
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                object lblMp4Fmt: TGLLabel
                  Transparent = True
                  Left = 8
                  Top = 46
                  Width = 84
                  Height = 15
                  Caption = 'Export PCM as'
                end
                object cboMp4Fmt: TGLCombo
                  Left = 100
                  Top = 42
                  Width = 120
                  Height = 23
                  TabOrder = 0
                end
              end
            end
            object tabScope: TGLPage
              Caption = 'Scope'
              object pnlScopeTop: TGLPanel
                Left = 0
                Top = 0
                Width = 952
                Height = 72
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                object lblScopeSignal: TGLLabel
                  Transparent = True
                  Left = 8
                  Top = 6
                  Width = 32
                  Height = 15
                  Caption = 'Signal'
                end
                object lblScopeMode: TGLLabel
                  Transparent = True
                  Left = 200
                  Top = 6
                  Width = 22
                  Height = 15
                  Caption = 'View'
                end
                object cboScopeSignal: TGLCombo
                  Left = 8
                  Top = 22
                  Width = 180
                  Height = 23
                  TabOrder = 0
                end
                object cboScopeMode: TGLCombo
                  Left = 200
                  Top = 22
                  Width = 180
                  Height = 23
                  TabOrder = 1
                end
                object chkScopeLive: TGLCheck
                  Left = 512
                  Top = 24
                  Width = 90
                  Height = 17
                  Caption = 'Live'
                  TabOrder = 3
                  OnClick = chkScopeLiveClick
                end
              end
              object pnlScopeReadout: TGLPanel
                Left = 0
                Top = 381
                Width = 952
                Height = 150
                Align = alBottom
                BevelOuter = bvNone
                TabOrder = 1
              end
              object pbScope: TGLView
                Left = 0
                Top = 72
                Width = 952
                Height = 309
                Align = alClient
                PopupMenu = pmScope
                OnPaint = pbScopePaint
              end
            end
            object tabAdvDsp: TGLPage
              Caption = 'Advanced DSP'
              object pnlAdvDspTop: TGLPanel
                Left = 0
                Top = 0
                Width = 952
                Height = 72
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                object lblAdvDspSignal: TGLLabel
                  Transparent = True
                  Left = 8
                  Top = 6
                  Width = 32
                  Height = 15
                  Caption = 'Signal'
                end
                object lblAdvDspProcess: TGLLabel
                  Transparent = True
                  Left = 200
                  Top = 6
                  Width = 40
                  Height = 15
                  Caption = 'Process'
                end
                object lblAdvDspParam: TGLLabel
                  Transparent = True
                  Left = 452
                  Top = 6
                  Width = 100
                  Height = 15
                  Caption = 'Stretch / semitones'
                end
                object cboAdvDspSignal: TGLCombo
                  Left = 8
                  Top = 22
                  Width = 180
                  Height = 23
                  TabOrder = 0
                end
                object cboAdvDspProcess: TGLCombo
                  Left = 200
                  Top = 22
                  Width = 240
                  Height = 23
                  TabOrder = 1
                end
                object edtAdvDspParam: TGLEdit
                  Left = 452
                  Top = 22
                  Width = 100
                  Height = 23
                  TabOrder = 2
                  Text = '2.0'
                end
              end
            end
          end
        end
      end
    end
    object tabBrowser: TGLPage
      Caption = 'Browser'
      ImageIndex = 17
      object pnlBrowserTop: TGLPanel
        Left = 0
        Top = 0
        Width = 952
        Height = 58
        Align = alTop
        BevelOuter = bvNone
        TabOrder = 0
        object lblBrowserHint: TGLLabel
          Transparent = True
          Left = 8
          Top = 38
          Width = 500
          Height = 15
          Caption = 'Select a Timeline audio channel, then add at the playhead; drag also works'
        end
        object btnBrowserAddFolder: TGLButton
          Left = 8
          Top = 6
          Width = 110
          Height = 25
          Caption = 'Add folder...'
          TabOrder = 0
          OnClick = btnBrowserAddFolderClick
        end
        object btnBrowserRefresh: TGLButton
          Left = 124
          Top = 6
          Width = 60
          Height = 25
          Caption = 'Refresh'
          TabOrder = 1
          OnClick = btnBrowserRefreshClick
        end
        object btnBrowserImport: TGLButton
          Left = 190
          Top = 6
          Width = 60
          Height = 25
          Caption = 'Import'
          TabOrder = 2
          OnClick = btnBrowserImportClick
        end
        object btnBrowserAddToSelected: TGLButton
          Left = 256
          Top = 6
          Width = 133
          Height = 25
          Caption = 'Add to selected track'
          TabOrder = 3
          OnClick = btnBrowserAddToSelectedClick
        end
      end
      object tvBrowser: TGLTree
        Left = 0
        Top = 58
        Width = 952
        Height = 332
        Align = alClient
        Indent = 19
        TabOrder = 2
        OnExpanding = tvBrowserExpanding
        OnMouseDown = tvBrowserMouseDown
      end
      object lblBrowserFloating: TGLLabel
        Left = 0
        Top = 58
        Width = 952
        Height = 332
        Align = alClient
        Alignment = taCenter
        Layout = tlCenter
        Caption = 'Browser is open in a separate window.'
        Visible = False
      end
    end
    object tabAI: TGLPage
      Caption = 'AI/SI'
      TabVisible = False
    end
  end
  object stbMain: TGLStatusBar
    Left = 0
    Top = 601
    Width = 960
    Height = 19
    Panels = <>
    SimplePanel = True
  end
  object prgStatus: TGLCapsuleProgress
    Left = 554
    Top = 604
    Width = 400
    Height = 16
    Anchors = [akRight, akBottom]
    Min = 0
    Max = 100
    TabStop = False
    Visible = False
  end
  object lblGlFps: TGLLabel
    Left = 700
    Top = 2
    Width = 262
    Height = 20
    Anchors = [akTop, akRight]
    Alignment = taRightJustify
    AutoSize = False
    Layout = tlCenter
    Sunken = True
    Caption = ' '
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -13
    Font.Name = 'Consolas'
    Font.Style = [fsBold]
    ParentFont = False
    Transparent = False
    Visible = False
  end
  object tmrGlFps: TTimer
    Enabled = False
    OnTimer = tmrGlFpsTimer
    Left = 848
    Top = 8
  end
  object tmrUI: TTimer
    Interval = 500
    OnTimer = tmrUITimer
    Left = 880
    Top = 8
  end
  object tmrTrkAnim: TTimer
    Interval = 16
    OnTimer = tmrTrkAnimTimer
    Left = 912
    Top = 8
  end
  object tmrTlEffMenu: TTimer
    Enabled = False
    OnTimer = tmrTlEffMenuTimer
    Left = 920
    Top = 8
  end
  object dlgSaveProject: TGLSaveDialog
    DefaultExt = 'udawproj'
    Filter = 'UDAW project (*.udawproj)|*.udawproj|All files (*.*)|*.*'
    Left = 880
    Top = 48
  end
  object dlgOpenProject: TGLOpenDialog
    DefaultExt = 'udawproj'
    Filter = 'UDAW project (*.udawproj)|*.udawproj|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 880
    Top = 88
  end
  object dlgOpenFoley: TGLOpenDialog
    Filter = 'Sound effects (*.wav;*.mp3)|*.wav;*.mp3|All files (*.*)|*.*'
    Title = 'Load a sound into the pad'
    Left = 880
    Top = 168
  end
  object dlgOpenWav: TGLOpenDialog
    DefaultExt = 'wav'
    Filter = 'WAV audio (*.wav)|*.wav|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 880
    Top = 128
  end
  object dlgSunoRefOpen: TGLOpenDialog
    DefaultExt = 'wav'
    Filter = 'Audio files (*.wav;*.mp3;*.flac)|*.wav;*.mp3;*.flac|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 880
    Top = 160
  end
  object dlgTimelineExport: TGLSaveDialog
    Filter = 'WAV - 24-bit stereo PCM|*.wav|MP3 - 320 kbps stereo|*.mp3|MP4 - AAC stereo audio|*.mp4|M4A - AAC stereo audio|*.m4a|Raw PCM - signed 16-bit stereo + metadata|*.pcm|FLAC - 24-bit lossless stereo|*.flac|MKV - video with audio|*.mkv'
    Options = [ofOverwritePrompt, ofHideReadOnly, ofPathMustExist, ofEnableSizing]
    Title = 'Export complete timeline mix'
    Left = 280
    Top = 16
  end
  object dlgSaveWav: TGLSaveDialog
    DefaultExt = 'wav'
    Filter = 'WAV audio (*.wav)|*.wav|All files (*.*)|*.*'
    Left = 880
    Top = 168
  end
  object dlgSaveLyrics: TGLSaveDialog
    DefaultExt = 'txt'
    Filter = 'Text file (*.txt)|*.txt|All files (*.*)|*.*'
    Options = [ofOverwritePrompt, ofPathMustExist, ofEnableSizing]
    Title = 'Save lyrics as text'
    Left = 920
    Top = 168
  end
  object pmSunoLyrics: TPopupMenu
    OnPopup = pmSunoLyricsPopup
    Left = 960
    Top = 168
    object pmSunoLyricsClear: TMenuItem
      Caption = 'Clear'
      OnClick = pmSunoLyricsClearClick
    end
    object pmSunoLyricsSep: TMenuItem
      Caption = '-'
    end
    object pmSunoLyricsSave: TMenuItem
      Caption = 'Save as .txt...'
      OnClick = pmSunoLyricsSaveClick
    end
    object pmSunoLyricsExportSep: TMenuItem
      Caption = '-'
    end
    object pmSunoLyricsExport: TMenuItem
      Caption = 'Export'
      object pmSunoLyricsExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmSunoLyricsExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmSunoLyricsExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmSunoLyricsExportMkv: TMenuItem
        Caption = 'MKV...'
        OnClick = pmTlExportMkvClick
      end
      object pmSunoLyricsExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object dlgOpenVst: TGLOpenDialog
    DefaultExt = 'dll'
    Filter = 
      'Plugins (*.dll;*.clap;*.vst3)|*.dll;*.clap;*.vst3|VST2 plugin (*.dl' +
      'l)|*.dll|CLAP plugin (*.clap)|*.clap|VST3 plugin (*.vst3)|*.vst3|All' +
      ' files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 880
    Top = 264
  end
  object dlgOpenPattern: TGLOpenDialog
    DefaultExt = 'udawpattern'
    Filter = 'UDAW pattern (*.udawpattern)|*.udawpattern|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 880
    Top = 288
  end
  object dlgSavePattern: TGLSaveDialog
    DefaultExt = 'udawpattern'
    Filter = 'UDAW pattern (*.udawpattern)|*.udawpattern|All files (*.*)|*.*'
    Left = 880
    Top = 328
  end
  object dlgOpenMod: TGLOpenDialog
    DefaultExt = 'mod'
    Filter = 'ProTracker module (*.mod)|*.mod|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 880
    Top = 208
  end
  object dlgOpenTrkAny: TGLOpenDialog
    DefaultExt = 'xm'
    Filter =
      'Tracker modules (*.mod;*.xm;*.it;*.mptm;*.s3m)|*.mod;*.xm;*.it;*.mptm;*.s3m|' +
      'ScreamTracker 3 modules (*.s3m)|*.s3m|' +
      'All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 912
    Top = 208
  end
  object dlgSaveScorePdf: TGLSaveDialog
    DefaultExt = 'pdf'
    Filter = 'PDF document (*.pdf)|*.pdf|All files (*.*)|*.*'
    Options = [ofOverwritePrompt]
    Left = 944
    Top = 208
  end
  object dlgSaveMod: TGLSaveDialog
    DefaultExt = 'mod'
    Filter = 'ProTracker module (*.mod)|*.mod|All files (*.*)|*.*'
    Left = 880
    Top = 248
  end
  object dlgOpenXm: TGLOpenDialog
    DefaultExt = 'xm'
    Filter = 'FastTracker 2 module (*.xm)|*.xm|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 816
    Top = 208
  end
  object dlgSaveXm: TGLSaveDialog
    DefaultExt = 'xm'
    Filter = 'FastTracker 2 module (*.xm)|*.xm|All files (*.*)|*.*'
    Left = 816
    Top = 248
  end
  object dlgOpenMptm: TGLOpenDialog
    DefaultExt = 'mptm'
    Filter = 'OpenMPT / IT module (*.mptm;*.it)|*.mptm;*.it|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 752
    Top = 208
  end
  object dlgSaveMptm: TGLSaveDialog
    DefaultExt = 'mptm'
    Filter = 'OpenMPT module (*.mptm)|*.mptm|All files (*.*)|*.*'
    Left = 752
    Top = 248
  end
  object dlgOpenMp3: TGLOpenDialog
    DefaultExt = 'mp3'
    Filter = 'MP3 audio (*.mp3)|*.mp3|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 688
    Top = 208
  end
  object dlgSaveMp3: TGLSaveDialog
    DefaultExt = 'mp3'
    Filter = 'MP3 audio (*.mp3)|*.mp3|All files (*.*)|*.*'
    Left = 688
    Top = 248
  end
  object dlgOpenMp4: TGLOpenDialog
    DefaultExt = 'mp4'
    Filter = 'Video and audio (*.mp4;*.m4a;*.m4v;*.mov;*.mkv;*.webm)|*.mp4;*.m4a;*.m4v;*.mov;*.mkv;*.webm|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 688
    Top = 288
  end
  object dlgOpenFlac: TGLOpenDialog
    DefaultExt = 'flac'
    Filter = 'FLAC audio (*.flac)|*.flac|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 688
    Top = 368
  end
  object dlgOpenAls: TGLOpenDialog
    DefaultExt = 'als'
    Filter = 'Ableton Live Set (*.als)|*.als|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 688
    Top = 408
  end
  object dlgOpenFlp: TGLOpenDialog
    DefaultExt = 'flp'
    Filter = 'FL Studio Project (*.flp)|*.flp|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 688
    Top = 448
  end
  object dlgSaveMp4: TGLSaveDialog
    DefaultExt = 'mp4'
    Filter = 'MP4 audio (*.mp4;*.m4a)|*.mp4;*.m4a|All files (*.*)|*.*'
    Left = 688
    Top = 328
  end
  object dlgOpenPy: TGLOpenDialog
    DefaultExt = 'py'
    Filter = 'Python script (*.py)|*.py|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 800
    Top = 288
  end
  object dlgOpenMidi: TGLOpenDialog
    DefaultExt = 'mid'
    Filter = 'Standard MIDI File (*.mid;*.midi)|*.mid;*.midi|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 760
    Top = 288
  end
  object dlgSaveMidi: TGLSaveDialog
    DefaultExt = 'mid'
    Filter = 'Standard MIDI File (*.mid;*.midi)|*.mid;*.midi|All files (*.*)|*.*'
    Left = 760
    Top = 328
  end
  object mnuMain: TMainMenu
    Left = 16
    Top = 16
    object mnuProject: TMenuItem
      Caption = 'Project'
      object mnuProjectFile: TMenuItem
        Caption = 'File'
        object mnuProjectNew: TMenuItem
          Caption = 'New'
          ShortCut = 16462
          OnClick = btnProjectNewClick
        end
        object mnuProjectOpen: TMenuItem
          Caption = 'Open...'
          ShortCut = 16463
          OnClick = btnProjectOpenClick
        end
        object mnuProjectSepOpen: TMenuItem
          Caption = '-'
        end
        object mnuProjectRecent: TMenuItem
          Caption = 'Recent Projects'
        end
        object mnuProjectSepRecent: TMenuItem
          Caption = '-'
        end
        object mnuProjectSave: TMenuItem
          Caption = 'Save'
          ShortCut = 16467
          OnClick = btnProjectSaveClick
        end
        object mnuProjectSaveAs: TMenuItem
          Caption = 'Save As...'
          ShortCut = 24659
          OnClick = btnProjectSaveAsClick
        end
      end
      object mnuProjectAutosave: TMenuItem
        Caption = 'Autosave'
        object mnuProjectAutosaveNow: TMenuItem
          Caption = 'Autosave now'
          OnClick = btnAutosaveNowClick
        end
        object mnuProjectRecover: TMenuItem
          Caption = 'Recover unsaved changes'
          OnClick = btnRecoverClick
        end
      end
      object mnuProjectSepExit: TMenuItem
        Caption = '-'
      end
      object mnuProjectExit: TMenuItem
        Caption = 'Exit UDAW'
        ShortCut = 32883
        OnClick = mnuProjectExitClick
      end
    end
    object mnuEdit: TMenuItem
      Caption = 'Edit'
      object mnuProjectUndo: TMenuItem
        Caption = 'Undo'
        OnClick = btnUndoClick
      end
      object mnuProjectRedo: TMenuItem
        Caption = 'Redo'
        OnClick = btnRedoClick
      end
      object mnuTlEdit: TMenuItem
        Caption = 'Timeline'
        Visible = False
        object mnuTlUndo: TMenuItem
          Caption = 'Undo'
          OnClick = btnTlUndoClick
        end
        object mnuTlRedo: TMenuItem
          Caption = 'Redo'
          OnClick = btnTlRedoClick
        end
        object mnuTlEditSep1: TMenuItem
          Caption = '-'
        end
        object mnuTlCut: TMenuItem
          Caption = 'Cut'
          OnClick = btnTlCutClick
        end
        object mnuTlCopy: TMenuItem
          Caption = 'Copy'
          OnClick = btnTlCopyClick
        end
        object mnuTlPaste: TMenuItem
          Caption = 'Paste at playhead'
          OnClick = btnTlPasteClick
        end
        object mnuTlLockClip: TMenuItem
          Caption = 'Lock Clip'
          OnClick = btnTlLockClipClick
        end
        object mnuTlClampTo: TMenuItem
          Caption = 'Clamp to'
          object mnuTlClampLast: TMenuItem
            Tag = 1
            Caption = 'Clamp to Last Segment'
            OnClick = TlClampToClick
          end
          object mnuTlClampNext: TMenuItem
            Tag = 2
            Caption = 'Clamp to Next Segment'
            OnClick = TlClampToClick
          end
        end
        object mnuTlEditSepSel: TMenuItem
          Caption = '-'
        end
        object mnuTlCutSelection: TMenuItem
          Caption = 'Cut Selection'
          OnClick = pmTlCutSelectionClick
        end
        object mnuTlCopySelection: TMenuItem
          Caption = 'Copy Selection'
          OnClick = pmTlCopySelectionClick
        end
        object mnuTlPasteSelection: TMenuItem
          Caption = 'Paste Selection'
          OnClick = pmTlPasteSelectionClick
        end
        object mnuTlEditSep3: TMenuItem
          Caption = '-'
        end
        object mnuTlWarp: TMenuItem
          Caption = 'WARP'
          object mnuTlWarpAdd: TMenuItem
            Tag = 1
            Caption = 'Add Marker at Playhead'
            OnClick = TlWarpMenuClick
          end
          object mnuTlWarpSnap: TMenuItem
            Tag = 2
            Caption = 'Snap Marker to Nearest Beat'
            OnClick = TlWarpMenuClick
          end
          object mnuTlWarpAuto: TMenuItem
            Tag = 3
            Caption = 'Auto-Detect Beats to Grid'
            OnClick = TlWarpMenuClick
          end
          object mnuTlWarpApply: TMenuItem
            Tag = 4
            Caption = 'Apply Markers'
            OnClick = TlWarpMenuClick
          end
          object mnuTlWarpClear: TMenuItem
            Tag = 5
            Caption = 'Clear Markers'
            OnClick = TlWarpMenuClick
          end
          object mnuTlClipTempo: TMenuItem
            Caption = 'Clip Tempo (BPM)...'
            OnClick = TlClipTempoClick
          end
        end
        object mnuTlEditSep4: TMenuItem
          Caption = '-'
        end
        object mnuTlEffects: TMenuItem
          Caption = 'Audio Effects'
          object mnuTlFxGrpVolume: TMenuItem
            Caption = 'Volume && Fades'
            object mnuTlFxFadeInSCurve: TMenuItem
              Tag = 105
              Caption = 'Fade In (S-Curve)'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxFadeInEqualPower: TMenuItem
              Tag = 106
              Caption = 'Fade In (Equal Power)'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxFadeInExponential: TMenuItem
              Tag = 107
              Caption = 'Fade In (Exponential)'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxFadeInLogarithmic: TMenuItem
              Tag = 108
              Caption = 'Fade In (Logarithmic)'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxFadeOutSCurve: TMenuItem
              Tag = 109
              Caption = 'Fade Out (S-Curve)'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxFadeOutEqualPower: TMenuItem
              Tag = 110
              Caption = 'Fade Out (Equal Power)'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxFadeOutExponential: TMenuItem
              Tag = 111
              Caption = 'Fade Out (Exponential)'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxFadeOutLogarithmic: TMenuItem
              Tag = 112
              Caption = 'Fade Out (Logarithmic)'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxAmplify: TMenuItem
              Tag = 12
              Caption = 'Amplify'
              OnClick = TlFxMenuClick
            end
            object mnuTlNormalizeRange: TMenuItem
              Caption = 'Normalize'
              OnClick = btnTlNormalizeRangeClick
            end
            object mnuTlFxFadeIn: TMenuItem
              Caption = 'Fade In'
              OnClick = TlFxFadeInClick
            end
            object mnuTlFxFadeOut: TMenuItem
              Caption = 'Fade Out'
              OnClick = TlFxFadeOutClick
            end
            object mnuTlFxSilence: TMenuItem
              Tag = 11
              Caption = 'Silence'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxLoudnessNormalize: TMenuItem
              Tag = 49
              Caption = 'Loudness Normalize (-16 LUFS)'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxPeakNormalize: TMenuItem
              Tag = 76
              Caption = 'Peak Normalize'
              OnClick = TlFxMenuClick
            end
          end
          object mnuTlFxGrpDynamics: TMenuItem
            Caption = 'Dynamics'
            object mnuTlFxLevelRider: TMenuItem
              Tag = 100
              Caption = 'Level Rider'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxDialogRider: TMenuItem
              Tag = 101
              Caption = 'Dialog Rider'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxTruePeakLimiter: TMenuItem
              Tag = 102
              Caption = 'True-Peak Limiter'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxParallelCompression: TMenuItem
              Tag = 96
              Caption = 'Parallel Compression'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxCompressor: TMenuItem
              Tag = 1
              Caption = 'Compressor'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxMultibandCompressor: TMenuItem
              Tag = 28
              Caption = 'Multiband Compressor'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxLimiter: TMenuItem
              Tag = 19
              Caption = 'Limiter'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxExpander: TMenuItem
              Tag = 15
              Caption = 'Expander'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxGate: TMenuItem
              Tag = 17
              Caption = 'Gate'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxDeEsser: TMenuItem
              Tag = 13
              Caption = 'De-Esser'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxTransientShaper: TMenuItem
              Tag = 33
              Caption = 'Transient Shaper'
              OnClick = TlFxMenuClick
            end
          end
          object mnuTlFxGrpEQ: TMenuItem
            Caption = 'EQ && Filters'
            object mnuTlFxBassEnhance: TMenuItem
              Tag = 22
              Caption = 'Bass Enhance'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxBrightenEQ: TMenuItem
              Tag = 10
              Caption = 'Brighten (EQ)'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxPresenceBoost: TMenuItem
              Tag = 31
              Caption = 'Presence Boost'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxTrebleBoost: TMenuItem
              Tag = 34
              Caption = 'Treble Boost'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxHighPassFilter: TMenuItem
              Tag = 25
              Caption = 'High-Pass Filter'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxLowPassFilter: TMenuItem
              Tag = 26
              Caption = 'Low-Pass Filter'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxNotchFilter: TMenuItem
              Tag = 29
              Caption = 'Notch Filter'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxBandPassFilter: TMenuItem
              Tag = 54
              Caption = 'Band-Pass Filter'
              OnClick = TlFxMenuClick
            end
          end
          object mnuTlFxGrpDistortion: TMenuItem
            Caption = 'Distortion && Saturation'
            object mnuTlFxOversampledSaturation: TMenuItem
              Tag = 103
              Caption = 'Oversampled Saturation'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxBitCrusher: TMenuItem
              Tag = 9
              Caption = 'Bit Crusher'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxExciter: TMenuItem
              Tag = 24
              Caption = 'Exciter'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxFoldback: TMenuItem
              Tag = 16
              Caption = 'Foldback'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxHardClip: TMenuItem
              Tag = 18
              Caption = 'Hard Clip'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxSoftClip: TMenuItem
              Tag = 41
              Caption = 'Soft Clip'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxSaturation: TMenuItem
              Tag = 8
              Caption = 'Saturation'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxTube: TMenuItem
              Tag = 40
              Caption = 'Tube Saturation'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxLoFi: TMenuItem
              Tag = 57
              Caption = 'Lo-Fi'
              OnClick = TlFxMenuClick
            end
          end
          object mnuTlFxGrpModulation: TMenuItem
            Caption = 'Modulation'
            object mnuTlFxAutoPan: TMenuItem
              Tag = 7
              Caption = 'Auto-Pan'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxChorus: TMenuItem
              Tag = 3
              Caption = 'Chorus'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxFlanger: TMenuItem
              Tag = 4
              Caption = 'Flanger'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxPhaser: TMenuItem
              Tag = 5
              Caption = 'Phaser'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxTremolo: TMenuItem
              Tag = 6
              Caption = 'Tremolo'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxRingModulator: TMenuItem
              Tag = 45
              Caption = 'Ring Modulator'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxVibrato: TMenuItem
              Tag = 46
              Caption = 'Vibrato'
              OnClick = TlFxMenuClick
            end
          end
          object mnuTlFxGrpTimeSpace: TMenuItem
            Caption = 'Delay && Reverb'
            object mnuTlFxMultiTapDelay: TMenuItem
              Tag = 93
              Caption = 'Multi-Tap Delay'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxTapeDelay: TMenuItem
              Tag = 94
              Caption = 'Tape Delay'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxDelay: TMenuItem
              Tag = 14
              Caption = 'Delay'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxPingPongDelay: TMenuItem
              Tag = 20
              Caption = 'Ping-Pong Delay'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxReverb: TMenuItem
              Tag = 2
              Caption = 'Reverb'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxConvolutionReverb: TMenuItem
              Tag = 37
              Caption = 'Convolution Reverb...'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxEcho: TMenuItem
              Tag = 42
              Caption = 'Echo'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxSlapbackDelay: TMenuItem
              Tag = 56
              Caption = 'Slapback Delay'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxHallReverb: TMenuItem
              Tag = 58
              Caption = 'Hall Reverb'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxRoomReverb: TMenuItem
              Tag = 59
              Caption = 'Room Reverb'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxPlateReverb: TMenuItem
              Tag = 60
              Caption = 'Plate Reverb'
              OnClick = TlFxMenuClick
            end
          end
          object mnuTlFxGrpPitch: TMenuItem
            Caption = 'Pitch'
            object mnuTlFxPitchShift: TMenuItem
              Tag = 30
              Caption = 'Pitch Shift'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxAutoTune: TMenuItem
              Tag = 36
              Caption = 'Auto-Tune...'
              OnClick = TlFxMenuClick
            end
          end
          object mnuTlFxGrpStereo: TMenuItem
            Caption = 'Stereo'
            object mnuTlFxBalance: TMenuItem
              Tag = 21
              Caption = 'Balance'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxMakeMono: TMenuItem
              Tag = 27
              Caption = 'Make Mono'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxStereoWidener: TMenuItem
              Tag = 32
              Caption = 'Stereo Widener'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxSwapChannels: TMenuItem
              Tag = 43
              Caption = 'Swap Channels'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxInvertPhase: TMenuItem
              Tag = 44
              Caption = 'Invert Phase'
              OnClick = TlFxMenuClick
            end
          end
          object mnuTlFxGrpRestore: TMenuItem
            Caption = 'Restoration'
            object mnuTlFxDePopper: TMenuItem
              Tag = 99
              Caption = 'De-Popper (Plosive Remover)'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxAdaptiveNoiseReduction: TMenuItem
              Tag = 104
              Caption = 'Adaptive Noise Reduction'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxNoiseReduction: TMenuItem
              Tag = 35
              Caption = 'Noise Reduction...'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxDCOffsetRemover: TMenuItem
              Tag = 23
              Caption = 'DC Offset Remover'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxDeHummer50: TMenuItem
              Tag = 50
              Caption = 'De-Hummer (50 Hz)'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxDeHummer60: TMenuItem
              Tag = 51
              Caption = 'De-Hummer (60 Hz)'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxDeClicker: TMenuItem
              Tag = 52
              Caption = 'De-Clicker'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxDeClipper: TMenuItem
              Tag = 53
              Caption = 'De-Clipper'
              OnClick = TlFxMenuClick
            end
          end
          object mnuTlFxGrpVoice: TMenuItem
            Caption = 'Voice'
            object mnuTlFxVoiceIsolation: TMenuItem
              Tag = 115
              Caption = 'Voice Isolation'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxMusicSeparator: TMenuItem
              Tag = 116
              Caption = 'Music Separator'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxVocalChannel: TMenuItem
              Tag = 47
              Caption = 'Vocal Channel'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxDialogueLeveler: TMenuItem
              Tag = 48
              Caption = 'Dialogue Leveler'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxTelephone: TMenuItem
              Tag = 55
              Caption = 'Telephone'
              OnClick = TlFxMenuClick
            end
          end
          object mnuTlFxGrpCreative: TMenuItem
            Caption = 'Creative'
            object mnuTlFxTapeWowFlutter: TMenuItem
              Tag = 88
              Caption = 'Tape Wow && Flutter'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxAMRadio: TMenuItem
              Tag = 89
              Caption = 'AM Radio'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxFuzz: TMenuItem
              Tag = 90
              Caption = 'Fuzz'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxOctaveUpRectifier: TMenuItem
              Tag = 91
              Caption = 'Octave-Up Rectifier'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxStringEnsemble: TMenuItem
              Tag = 92
              Caption = 'String Ensemble'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxStutter: TMenuItem
              Tag = 95
              Caption = 'Stutter'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxVocoder: TMenuItem
              Tag = 77
              Caption = 'Vocoder'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxFrequencyShifter: TMenuItem
              Tag = 66
              Caption = 'Frequency Shifter'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxAutoWah: TMenuItem
              Tag = 67
              Caption = 'Auto-Wah'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxRobotVoice: TMenuItem
              Tag = 68
              Caption = 'Robot Voice'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxMegaphone: TMenuItem
              Tag = 69
              Caption = 'Megaphone'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxUnderwater: TMenuItem
              Tag = 70
              Caption = 'Underwater'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxTapeStop: TMenuItem
              Tag = 71
              Caption = 'Tape Stop'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxTranceGate: TMenuItem
              Tag = 72
              Caption = 'Trance Gate'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxRotarySpeaker: TMenuItem
              Tag = 73
              Caption = 'Rotary Speaker'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxVinylCrackle: TMenuItem
              Tag = 74
              Caption = 'Vinyl Crackle'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxCombFilter: TMenuItem
              Tag = 75
              Caption = 'Comb Filter'
              OnClick = TlFxMenuClick
            end
          end
          object mnuTlFxGrpStereoBass: TMenuItem
            Caption = 'Stereo && Bass'
            object mnuTlFxHaasWidener: TMenuItem
              Tag = 85
              Caption = 'Haas Widener'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxMonoBass: TMenuItem
              Tag = 86
              Caption = 'Mono Bass'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxVocalRemover: TMenuItem
              Tag = 87
              Caption = 'Vocal Remover'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxStereoFixer: TMenuItem
              Tag = 61
              Caption = 'Stereo Fixer'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxMidSideBalance: TMenuItem
              Tag = 62
              Caption = 'Mid/Side Balance'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxHeadphoneCrossfeed: TMenuItem
              Tag = 63
              Caption = 'Headphone Crossfeed'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxLFEFilter: TMenuItem
              Tag = 64
              Caption = 'LFE Filter'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxSubBassSynth: TMenuItem
              Tag = 65
              Caption = 'Sub Bass Synth'
              OnClick = TlFxMenuClick
            end
          end
          object mnuTlFxGrpToneFilters: TMenuItem
            Caption = 'Tone && Filters'
            object mnuTlFxWahWah: TMenuItem
              Tag = 78
              Caption = 'Wah-Wah'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxAutoFilter: TMenuItem
              Tag = 79
              Caption = 'Auto-Filter'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxVowelAh: TMenuItem
              Tag = 80
              Caption = 'Vowel Filter (Ah)'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxVowelEh: TMenuItem
              Tag = 81
              Caption = 'Vowel Filter (Eh)'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxVowelEe: TMenuItem
              Tag = 82
              Caption = 'Vowel Filter (Ee)'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxVowelOh: TMenuItem
              Tag = 83
              Caption = 'Vowel Filter (Oh)'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxVowelOo: TMenuItem
              Tag = 84
              Caption = 'Vowel Filter (Oo)'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxTiltBrighter: TMenuItem
              Tag = 97
              Caption = 'Tilt EQ (Brighter)'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxTiltDarker: TMenuItem
              Tag = 98
              Caption = 'Tilt EQ (Darker)'
              OnClick = TlFxMenuClick
            end
          end
          object mnuTlFxGrpTools: TMenuItem
            Caption = 'Tools'
            object mnuTlFxAudioToMidi: TMenuItem
              Tag = 39
              Caption = 'Audio to MIDI...'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxEditLane: TMenuItem
              Caption = 'Edit Lane...'
              OnClick = TlEditLaneClick
            end
            object mnuTlFxLoudnessReport: TMenuItem
              Tag = 113
              Caption = 'Loudness && Phase Report'
              OnClick = TlFxMenuClick
            end
            object mnuTlReverseRange: TMenuItem
              Caption = 'Reverse'
              OnClick = btnTlReverseRangeClick
            end
            object mnuTlFxSplitSpeechMusic: TMenuItem
              Tag = 114
              Caption = 'Split Speech / Music'
              OnClick = TlFxMenuClick
            end
            object mnuTlFxSplitStems: TMenuItem
              Tag = 38
              Caption = 'Split Stems (Drums/Bass/Vocals/Other)'
              OnClick = TlFxMenuClick
            end
          end
          object mnuTlFxPlugin: TMenuItem
            Caption = 'Plug-in (VST3 / VST2 / CLAP)...'
            OnClick = TlFxPluginClick
          end
          object mnuTlFxSepUndo: TMenuItem
            Caption = '-'
          end
          object mnuTlUndoEffect: TMenuItem
            Caption = 'Undo Effect'
            OnClick = TlUndoEffectClick
          end
        end
        object mnuTlVideoEffects: TMenuItem
          Caption = 'Video Effects'
          object mnuTlVfxTransitions: TMenuItem
            Caption = 'Transitions'
            object mnuTlVfxGrpDissolve: TMenuItem
              Caption = 'Dissolve'
              object mnuTlVfxCrossfade: TMenuItem
                Tag = 0
                Caption = 'Cross Dissolve'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxDipblack: TMenuItem
                Tag = 1
                Caption = 'Dip to Black'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxDipwhite: TMenuItem
                Tag = 2
                Caption = 'Dip to White'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxBlurdissolve: TMenuItem
                Tag = 3
                Caption = 'Blur Dissolve'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxPixeldissolve: TMenuItem
                Tag = 4
                Caption = 'Pixelate Dissolve'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxAdditive: TMenuItem
                Tag = 52
                Caption = 'Additive Dissolve'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxNonadditive: TMenuItem
                Tag = 53
                Caption = 'Non-Additive Dissolve'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxDitherdissolve: TMenuItem
                Tag = 54
                Caption = 'Dither Dissolve'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxBurnaway: TMenuItem
                Tag = 55
                Caption = 'Burn Away'
                OnClick = TlVideoFxMenuClick
              end
            end
            object mnuTlVfxGrpIris: TMenuItem
              Caption = 'Iris'
              object mnuTlVfxCircleopen: TMenuItem
                Tag = 11
                Caption = 'Iris Open'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxCircleclose: TMenuItem
                Tag = 12
                Caption = 'Iris Close'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxIrisbox: TMenuItem
                Tag = 56
                Caption = 'Square Iris'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxIrisdiamond: TMenuItem
                Tag = 57
                Caption = 'Diamond Iris'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxIrisoval: TMenuItem
                Tag = 58
                Caption = 'Oval Iris'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxIriscross: TMenuItem
                Tag = 59
                Caption = 'Cross Iris'
                OnClick = TlVideoFxMenuClick
              end
            end
            object mnuTlVfxGrpWipe: TMenuItem
              Caption = 'Wipe'
              object mnuTlVfxWipeleft: TMenuItem
                Tag = 5
                Caption = 'Wipe Left'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxWiperight: TMenuItem
                Tag = 6
                Caption = 'Wipe Right'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxWipeup: TMenuItem
                Tag = 7
                Caption = 'Wipe Up'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxWipedown: TMenuItem
                Tag = 8
                Caption = 'Wipe Down'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxClock: TMenuItem
                Tag = 9
                Caption = 'Clock Wipe'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxBarndoor: TMenuItem
                Tag = 10
                Caption = 'Barn Doors'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxBandwipe: TMenuItem
                Tag = 68
                Caption = 'Band Wipe'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxVenetian: TMenuItem
                Tag = 69
                Caption = 'Venetian Blinds'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxVenetianv: TMenuItem
                Tag = 70
                Caption = 'Vertical Blinds'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxCheckerwipe: TMenuItem
                Tag = 71
                Caption = 'Checker Wipe'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxDiagwipe: TMenuItem
                Tag = 72
                Caption = 'Diagonal Wipe (Top Left)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxDiagwipe2: TMenuItem
                Tag = 73
                Caption = 'Diagonal Wipe (Top Right)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxPinwheel: TMenuItem
                Tag = 74
                Caption = 'Pinwheel'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxFanwipe: TMenuItem
                Tag = 75
                Caption = 'Fan Wipe'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSpiralwipe: TMenuItem
                Tag = 76
                Caption = 'Spiral Wipe'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxZigzagwipe: TMenuItem
                Tag = 77
                Caption = 'Zig-Zag Wipe'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxXwipe: TMenuItem
                Tag = 78
                Caption = 'X Wipe'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxBlockwipe: TMenuItem
                Tag = 79
                Caption = 'Random Blocks'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxInsetwipe: TMenuItem
                Tag = 80
                Caption = 'Inset Wipe'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxLumawipe: TMenuItem
                Tag = 81
                Caption = 'Luma Wipe'
                OnClick = TlVideoFxMenuClick
              end
            end
            object mnuTlVfxGrpMotion: TMenuItem
              Caption = 'Motion'
              object mnuTlVfxSlideleft: TMenuItem
                Tag = 13
                Caption = 'Push Left'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSlideright: TMenuItem
                Tag = 14
                Caption = 'Push Right'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSlideup: TMenuItem
                Tag = 15
                Caption = 'Push Up'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSlidedown: TMenuItem
                Tag = 16
                Caption = 'Push Down'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxZoomin: TMenuItem
                Tag = 17
                Caption = 'Zoom In'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxZoomout: TMenuItem
                Tag = 18
                Caption = 'Zoom Out'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxGlitchtrans: TMenuItem
                Tag = 19
                Caption = 'Glitch Transition'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxCoverleft: TMenuItem
                Tag = 82
                Caption = 'Slide Left'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxCoverright: TMenuItem
                Tag = 83
                Caption = 'Slide Right'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxCoverup: TMenuItem
                Tag = 84
                Caption = 'Slide Up'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxCoverdown: TMenuItem
                Tag = 85
                Caption = 'Slide Down'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSplith: TMenuItem
                Tag = 86
                Caption = 'Split Open (Horizontal)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSplitv: TMenuItem
                Tag = 87
                Caption = 'Split Open (Vertical)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSqueezeh: TMenuItem
                Tag = 88
                Caption = 'Squeeze (Horizontal)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSqueezev: TMenuItem
                Tag = 89
                Caption = 'Squeeze (Vertical)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxCardflipx: TMenuItem
                Tag = 90
                Caption = 'Card Flip (Horizontal)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxCardflipy: TMenuItem
                Tag = 91
                Caption = 'Card Flip (Vertical)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSpintrans: TMenuItem
                Tag = 92
                Caption = 'Spin Dissolve'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxWhippan: TMenuItem
                Tag = 93
                Caption = 'Whip Pan'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxRippletrans: TMenuItem
                Tag = 94
                Caption = 'Ripple Dissolve'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSwirltrans: TMenuItem
                Tag = 95
                Caption = 'Swirl Dissolve'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxZoomblurtrans: TMenuItem
                Tag = 96
                Caption = 'Zoom Blur Dissolve'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxBandslide: TMenuItem
                Tag = 97
                Caption = 'Band Slide'
                OnClick = TlVideoFxMenuClick
              end
            end
            object mnuTlVfxGrpShape: TMenuItem
              Caption = 'Shape'
              object mnuTlVfxShapeheart: TMenuItem
                Tag = 60
                Caption = 'Heart'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxShapestar: TMenuItem
                Tag = 61
                Caption = 'Star'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxShapetriup: TMenuItem
                Tag = 62
                Caption = 'Triangle Up'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxShapetridown: TMenuItem
                Tag = 63
                Caption = 'Triangle Down'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxShapetrileft: TMenuItem
                Tag = 64
                Caption = 'Triangle Left'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxShapetriright: TMenuItem
                Tag = 65
                Caption = 'Triangle Right'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxShapepentagon: TMenuItem
                Tag = 66
                Caption = 'Pentagon'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxShapehexagon: TMenuItem
                Tag = 67
                Caption = 'Hexagon'
                OnClick = TlVideoFxMenuClick
              end
            end
          end
          object mnuTlVfxFilters: TMenuItem
            Caption = 'Effects'
            object mnuTlVfxGrpFade: TMenuItem
              Caption = 'Fade'
              object mnuTlVfxFadein: TMenuItem
                Tag = 20
                Caption = 'Fade In'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxFadeout: TMenuItem
                Tag = 21
                Caption = 'Fade Out'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxFlash: TMenuItem
                Tag = 22
                Caption = 'Flash'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxBlurin: TMenuItem
                Tag = 98
                Caption = 'Blur In'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxBlurout: TMenuItem
                Tag = 99
                Caption = 'Blur Out'
                OnClick = TlVideoFxMenuClick
              end
            end
            object mnuTlVfxGrpBlur: TMenuItem
              Caption = 'Blur'
              object mnuTlVfxBlur: TMenuItem
                Tag = 23
                Caption = 'Box Blur'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxPixelate: TMenuItem
                Tag = 25
                Caption = 'Mosaic Blur'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxGaussian: TMenuItem
                Tag = 100
                Caption = 'Gaussian Blur'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxMotionblur: TMenuItem
                Tag = 101
                Caption = 'Motion Blur'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxDirectionalblur: TMenuItem
                Tag = 102
                Caption = 'Directional Blur (Vertical)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxRadialblur: TMenuItem
                Tag = 103
                Caption = 'Radial Blur'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxZoomblur: TMenuItem
                Tag = 104
                Caption = 'Zoom Blur'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxLensblur: TMenuItem
                Tag = 105
                Caption = 'Lens Blur'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxTiltshift: TMenuItem
                Tag = 106
                Caption = 'Tilt-Shift Blur'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxPrismblur: TMenuItem
                Tag = 107
                Caption = 'Prism Blur'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSoftfocus: TMenuItem
                Tag = 108
                Caption = 'Soft Focus'
                OnClick = TlVideoFxMenuClick
              end
            end
            object mnuTlVfxGrpSharpen: TMenuItem
              Caption = 'Sharpen'
              object mnuTlVfxSharpen: TMenuItem
                Tag = 24
                Caption = 'Sharpen'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxUnsharp: TMenuItem
                Tag = 109
                Caption = 'Unsharp Mask'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxUltrasharp: TMenuItem
                Tag = 110
                Caption = 'Ultra Sharpen'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSharpenedge: TMenuItem
                Tag = 111
                Caption = 'Sharpen Edges'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxEdgeenhance: TMenuItem
                Tag = 112
                Caption = 'Edge Enhance'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxClarity: TMenuItem
                Tag = 113
                Caption = 'Detail Recovery'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxTexturepop: TMenuItem
                Tag = 114
                Caption = 'Texture Pop'
                OnClick = TlVideoFxMenuClick
              end
            end
            object mnuTlVfxGrpColour: TMenuItem
              Caption = 'Colour'
              object mnuTlVfxBw: TMenuItem
                Tag = 26
                Caption = 'Black and White'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSepia: TMenuItem
                Tag = 27
                Caption = 'Sepia'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxInvert: TMenuItem
                Tag = 28
                Caption = 'Invert'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxDuotone: TMenuItem
                Tag = 29
                Caption = 'Duotone'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxTint: TMenuItem
                Tag = 30
                Caption = 'Colour Tint'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxWarm: TMenuItem
                Tag = 31
                Caption = 'Warm'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxCool: TMenuItem
                Tag = 32
                Caption = 'Cool'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxBrighten: TMenuItem
                Tag = 33
                Caption = 'Brighten'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxDarken: TMenuItem
                Tag = 34
                Caption = 'Darken'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxContrast: TMenuItem
                Tag = 35
                Caption = 'Contrast'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxVivid: TMenuItem
                Tag = 36
                Caption = 'Vivid'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxDesaturate: TMenuItem
                Tag = 37
                Caption = 'Desaturate'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxPosterize: TMenuItem
                Tag = 38
                Caption = 'Posterize'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxHueshift: TMenuItem
                Tag = 115
                Caption = 'Hue Shift'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxHuecycle: TMenuItem
                Tag = 116
                Caption = 'Hue Cycle'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxExposure: TMenuItem
                Tag = 117
                Caption = 'Exposure'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxGamma: TMenuItem
                Tag = 118
                Caption = 'Gamma'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxAutolevels: TMenuItem
                Tag = 119
                Caption = 'Auto Levels'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxWhitebalance: TMenuItem
                Tag = 120
                Caption = 'Chromatic Adaptation (Auto White Balance)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSwaprb: TMenuItem
                Tag = 121
                Caption = 'Swap Red and Blue'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSolarize: TMenuItem
                Tag = 122
                Caption = 'Solarize'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxThreshold: TMenuItem
                Tag = 123
                Caption = 'Threshold'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxBleach: TMenuItem
                Tag = 124
                Caption = 'Bleach Bypass'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxCrossprocess: TMenuItem
                Tag = 125
                Caption = 'Cross Process'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxTealorange: TMenuItem
                Tag = 126
                Caption = 'Teal and Orange'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSplittone: TMenuItem
                Tag = 127
                Caption = 'Split Tone'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxFalsecolor: TMenuItem
                Tag = 128
                Caption = 'False Color'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxThermal: TMenuItem
                Tag = 129
                Caption = 'Thermal'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxNightvision: TMenuItem
                Tag = 130
                Caption = 'Night Vision'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxContrastpop: TMenuItem
                Tag = 131
                Caption = 'Contrast Pop'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxColorcompress: TMenuItem
                Tag = 132
                Caption = 'Color Compressor'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxMatte: TMenuItem
                Tag = 133
                Caption = 'Matte Fade'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxCyanotype: TMenuItem
                Tag = 134
                Caption = 'Cyanotype'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxColorpalette: TMenuItem
                Tag = 135
                Caption = 'Color Palette (Retro 16)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxDespill: TMenuItem
                Tag = 136
                Caption = 'Despill (Green)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxFilmlook: TMenuItem
                Tag = 137
                Caption = 'Film Look'
                OnClick = TlVideoFxMenuClick
              end
            end
            object mnuTlVfxGrpLight: TMenuItem
              Caption = 'Light'
              object mnuTlVfxVignette: TMenuItem
                Tag = 39
                Caption = 'Vignette'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxGlow: TMenuItem
                Tag = 138
                Caption = 'Glow'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxBloom: TMenuItem
                Tag = 139
                Caption = 'Bloom'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxHalation: TMenuItem
                Tag = 140
                Caption = 'Halation'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxCinematichaze: TMenuItem
                Tag = 141
                Caption = 'Cinematic Haze'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxLightrays: TMenuItem
                Tag = 142
                Caption = 'Light Rays'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxLensflare: TMenuItem
                Tag = 143
                Caption = 'Lens Flare'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxStarglow: TMenuItem
                Tag = 144
                Caption = 'Aperture Diffraction (Star Glow)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSpotlight: TMenuItem
                Tag = 145
                Caption = 'Spotlight'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxLightleak: TMenuItem
                Tag = 146
                Caption = 'Light Leak'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxStrobe: TMenuItem
                Tag = 147
                Caption = 'Strobe'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxFlicker: TMenuItem
                Tag = 148
                Caption = 'Flicker'
                OnClick = TlVideoFxMenuClick
              end
            end
            object mnuTlVfxGrpStylize: TMenuItem
              Caption = 'Stylize'
              object mnuTlVfxSketch: TMenuItem
                Tag = 42
                Caption = 'Sketch'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxEmboss: TMenuItem
                Tag = 43
                Caption = 'Emboss'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxEdgedetect: TMenuItem
                Tag = 149
                Caption = 'Edge Detect'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxPencil: TMenuItem
                Tag = 150
                Caption = 'Pencil Sketch'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxCartoon: TMenuItem
                Tag = 151
                Caption = 'Cartoon'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxOilpaint: TMenuItem
                Tag = 152
                Caption = 'Oil Paint'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxWatercolor: TMenuItem
                Tag = 153
                Caption = 'Watercolor'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxHalftone: TMenuItem
                Tag = 154
                Caption = 'Halftone'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxAnaglyph: TMenuItem
                Tag = 155
                Caption = 'Anaglyph 3D'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxAbstraction: TMenuItem
                Tag = 156
                Caption = 'Abstraction'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxXray: TMenuItem
                Tag = 157
                Caption = 'X-Ray'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxDither: TMenuItem
                Tag = 158
                Caption = 'Dither (Retro)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxShrink: TMenuItem
                Tag = 159
                Caption = 'Shrink (Erode)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxGrow: TMenuItem
                Tag = 160
                Caption = 'Grow (Dilate)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxJpegdamage: TMenuItem
                Tag = 161
                Caption = 'JPEG Damage'
                OnClick = TlVideoFxMenuClick
              end
            end
            object mnuTlVfxGrpTexture: TMenuItem
              Caption = 'Texture'
              object mnuTlVfxGrain: TMenuItem
                Tag = 40
                Caption = 'Film Grain'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxScanlines: TMenuItem
                Tag = 41
                Caption = 'Scanlines'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxNoise: TMenuItem
                Tag = 162
                Caption = 'Colour Noise'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxFilmdamage: TMenuItem
                Tag = 163
                Caption = 'Film Damage'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxOldfilm: TMenuItem
                Tag = 164
                Caption = 'Old Film'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxCanvas: TMenuItem
                Tag = 165
                Caption = 'Canvas'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxCrt: TMenuItem
                Tag = 166
                Caption = 'CRT Monitor'
                OnClick = TlVideoFxMenuClick
              end
            end
            object mnuTlVfxGrpTransform: TMenuItem
              Caption = 'Transform'
              object mnuTlVfxMirror: TMenuItem
                Tag = 46
                Caption = 'Mirror (Left to Right)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxFlipv: TMenuItem
                Tag = 47
                Caption = 'Flip Vertical'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxFliph: TMenuItem
                Tag = 167
                Caption = 'Flip Horizontal'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxMirrorv: TMenuItem
                Tag = 168
                Caption = 'Mirror (Top to Bottom)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxMirror4: TMenuItem
                Tag = 169
                Caption = 'Mirror (Four Way)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxKaleido: TMenuItem
                Tag = 170
                Caption = 'Kaleidoscope'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxTile: TMenuItem
                Tag = 171
                Caption = 'Tile'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxRot90: TMenuItem
                Tag = 172
                Caption = 'Rotate 90 Clockwise'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxRot180: TMenuItem
                Tag = 173
                Caption = 'Rotate 180'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxRot270: TMenuItem
                Tag = 174
                Caption = 'Rotate 90 Counter-Clockwise'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxZoomcrop: TMenuItem
                Tag = 175
                Caption = 'Crop and Zoom'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxKeystone: TMenuItem
                Tag = 176
                Caption = 'Keystone'
                OnClick = TlVideoFxMenuClick
              end
            end
            object mnuTlVfxGrpWarp: TMenuItem
              Caption = 'Warp'
              object mnuTlVfxBulge: TMenuItem
                Tag = 177
                Caption = 'Bulge'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxPinch: TMenuItem
                Tag = 178
                Caption = 'Dent (Pinch)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxBarrel: TMenuItem
                Tag = 179
                Caption = 'Lens Distortion'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxFisheye: TMenuItem
                Tag = 180
                Caption = 'Fisheye'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSwirl: TMenuItem
                Tag = 181
                Caption = 'Swirl'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxVortex: TMenuItem
                Tag = 182
                Caption = 'Vortex'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxRipple: TMenuItem
                Tag = 183
                Caption = 'Ripple'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxWave: TMenuItem
                Tag = 184
                Caption = 'Waviness'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxMagnify: TMenuItem
                Tag = 185
                Caption = 'Magnify'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxHeathaze: TMenuItem
                Tag = 186
                Caption = 'Heat Haze'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxUnderwater: TMenuItem
                Tag = 187
                Caption = 'Underwater'
                OnClick = TlVideoFxMenuClick
              end
            end
            object mnuTlVfxGrpGlitch: TMenuItem
              Caption = 'Glitch'
              object mnuTlVfxGlitch: TMenuItem
                Tag = 44
                Caption = 'Glitch'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxRgbsplit: TMenuItem
                Tag = 45
                Caption = 'RGB Split'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxChromatic: TMenuItem
                Tag = 188
                Caption = 'Chromatic Aberration'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxVhs: TMenuItem
                Tag = 189
                Caption = 'Analog Damage (VHS)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxBlockglitch: TMenuItem
                Tag = 190
                Caption = 'Digital Glitch'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxTvstatic: TMenuItem
                Tag = 191
                Caption = 'TV Static'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxInterlace: TMenuItem
                Tag = 192
                Caption = 'Interlace Tear'
                OnClick = TlVideoFxMenuClick
              end
            end
            object mnuTlVfxGrpRevival: TMenuItem
              Caption = 'Revival'
              object mnuTlVfxDenoise: TMenuItem
                Tag = 193
                Caption = 'Noise Reduction'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxDespeckle: TMenuItem
                Tag = 194
                Caption = 'Despeckle'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxDeadpixel: TMenuItem
                Tag = 195
                Caption = 'Dead Pixel Fixer'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxDeband: TMenuItem
                Tag = 196
                Caption = 'Deband'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxDehaze: TMenuItem
                Tag = 197
                Caption = 'Dehaze'
                OnClick = TlVideoFxMenuClick
              end
            end
            object mnuTlVfxGrpBeauty: TMenuItem
              Caption = 'Beauty'
              object mnuTlVfxSoftskin: TMenuItem
                Tag = 198
                Caption = 'Beauty (Soften Skin)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxGlamour: TMenuItem
                Tag = 199
                Caption = 'Glamour Glow'
                OnClick = TlVideoFxMenuClick
              end
            end
            object mnuTlVfxGrpGenerate: TMenuItem
              Caption = 'Generate'
              object mnuTlVfxLetterbox: TMenuItem
                Tag = 200
                Caption = 'Letterbox'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxBorder: TMenuItem
                Tag = 201
                Caption = 'Border'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxGradient: TMenuItem
                Tag = 202
                Caption = 'Gradient Overlay'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxGrid: TMenuItem
                Tag = 203
                Caption = 'Grid'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxColorbars: TMenuItem
                Tag = 204
                Caption = 'Color Bars'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxCheckerboard: TMenuItem
                Tag = 205
                Caption = 'Checkerboard'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSolid: TMenuItem
                Tag = 206
                Caption = 'Color Generator (Solid)'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxFastnoise: TMenuItem
                Tag = 207
                Caption = 'Fast Noise (Clouds)'
                OnClick = TlVideoFxMenuClick
              end
            end
            object mnuTlVfxGrpCameraMotion: TMenuItem
              Caption = 'Camera Motion'
              object mnuTlVfxShake: TMenuItem
                Tag = 48
                Caption = 'Shake'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSlowzoom: TMenuItem
                Tag = 49
                Caption = 'Slow Zoom In'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSpin: TMenuItem
                Tag = 50
                Caption = 'Spin'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxPulse: TMenuItem
                Tag = 51
                Caption = 'Zoom Pulse'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxSlowzoomout: TMenuItem
                Tag = 208
                Caption = 'Slow Zoom Out'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxPanleft: TMenuItem
                Tag = 209
                Caption = 'Pan Left'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxPanright: TMenuItem
                Tag = 210
                Caption = 'Pan Right'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxPanup: TMenuItem
                Tag = 211
                Caption = 'Pan Up'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxPandown: TMenuItem
                Tag = 212
                Caption = 'Pan Down'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxKenburns: TMenuItem
                Tag = 213
                Caption = 'Ken Burns'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxDutch: TMenuItem
                Tag = 214
                Caption = 'Dutch Angle'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxHandheld: TMenuItem
                Tag = 215
                Caption = 'Handheld'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxBounce: TMenuItem
                Tag = 216
                Caption = 'Bounce'
                OnClick = TlVideoFxMenuClick
              end
              object mnuTlVfxEarthquake: TMenuItem
                Tag = 217
                Caption = 'Earthquake'
                OnClick = TlVideoFxMenuClick
              end
            end
          end
          object mnuTlVfxSep: TMenuItem
            Caption = '-'
          end
          object mnuTlVfxRemove: TMenuItem
            Caption = 'Remove Video Effect at Playhead'
            OnClick = TlVideoFxRemoveClick
          end
        end
        object mnuTlEditSep2: TMenuItem
          Caption = '-'
        end
        object mnuTlRenameTrack: TMenuItem
          Caption = 'Rename Channel...'
          OnClick = pmTlRenameTrackClick
        end
        object mnuTlEditSep5: TMenuItem
          Caption = '-'
        end
        object mnuTlSaveSelWav: TMenuItem
          Tag = 1
          Caption = 'Save Selection as WAV...'
          OnClick = TlSaveSelectionClick
        end
        object mnuTlSaveSelPcm: TMenuItem
          Tag = 5
          Caption = 'Save Selection as PCM...'
          OnClick = TlSaveSelectionClick
        end
        object mnuTlSaveSelFlac: TMenuItem
          Tag = 6
          Caption = 'Save Selection as FLAC...'
          OnClick = TlSaveSelectionClick
        end
      end
      object mnuTrkEdit: TMenuItem
        Caption = 'Tracker'
        Visible = False
        object mnuTrkUndo: TMenuItem
          Caption = 'Undo'
          OnClick = btnTrkUndoClick
        end
        object mnuTrkRedo: TMenuItem
          Caption = 'Redo'
          OnClick = btnTrkRedoClick
        end
      end
      object mnuMixEdit: TMenuItem
        Caption = 'Mixer'
        Visible = False
        object mnuMixUndo: TMenuItem
          Caption = 'Undo'
          OnClick = btnMixUndoClick
        end
        object mnuMixRedo: TMenuItem
          Caption = 'Redo'
          OnClick = btnMixRedoClick
        end
      end
      object mnuMidiEdit: TMenuItem
        Caption = 'MIDI'
        Visible = False
        object mnuMidiUndo: TMenuItem
          Caption = 'Undo'
          OnClick = btnMidiUndoClick
        end
        object mnuMidiRedo: TMenuItem
          Caption = 'Redo'
          OnClick = btnMidiRedoClick
        end
      end
    end
    object mnuTracker: TMenuItem
      Caption = 'Tracker'
      Visible = False
      object mnuTrkNew: TMenuItem
        Caption = 'New'
        object mnuTrkNewTracker: TMenuItem
          Caption = 'Tracker'
          OnClick = mnuTrkNewTrackerClick
        end
      end
      object mnuTrkPattern: TMenuItem
        Caption = 'Pattern'
        object mnuTrkAddPattern: TMenuItem
          Caption = 'Add pattern'
          OnClick = btnTrkAddPatternClick
        end
        object mnuTrkDelPattern: TMenuItem
          Caption = 'Remove pattern'
          OnClick = btnTrkDelPatternClick
        end
      end
      object mnuTrkCell: TMenuItem
        Caption = 'Cell'
        object mnuTrkClearCell: TMenuItem
          Caption = 'Clear cell'
          OnClick = btnTrkClearCellClick
        end
        object mnuTrkFillDemo: TMenuItem
          Caption = 'Fill demo (sine arpeggio)'
          OnClick = btnTrkFillDemoClick
        end
      end
      object mnuTrkTransport: TMenuItem
        Caption = 'Transport'
        object mnuTrkApplyXport: TMenuItem
          Caption = 'Apply speed / BPM'
          OnClick = btnTrkApplyXportClick
        end
        object mnuTrkPlay: TMenuItem
          Caption = 'Play'
          OnClick = btnTrkPlayClick
        end
        object mnuTrkStop: TMenuItem
          Caption = 'Stop'
          OnClick = btnTrkStopClick
        end
      end
      object mnuTrkImport: TMenuItem
        Caption = 'Import'
        object mnuTrkImportMod: TMenuItem
          Caption = 'ProTracker .mod...'
          OnClick = btnTrkImportModClick
        end
        object mnuTrkImportXm: TMenuItem
          Caption = 'FastTracker .xm...'
          OnClick = btnTrkImportXmClick
        end
        object mnuTrkImportMptm: TMenuItem
          Caption = 'OpenMPT .mptm / .it...'
          OnClick = btnTrkImportMptmClick
        end
        object mnuTrkImportLegacy: TMenuItem
          Caption = 'ScreamTracker 3 (.s3m)...'
          OnClick = btnTrkImportLegacyClick
        end
      end
      object mnuTrkExport: TMenuItem
        Caption = 'Export'
        OnClick = mnuTrkExportClick
        object mnuTrkExportFiles: TMenuItem
          Caption = 'Files'
          object mnuTrkExportMod: TMenuItem
            Caption = 'ProTracker .mod...'
            OnClick = btnTrkExportModClick
          end
          object mnuTrkExportXm: TMenuItem
            Caption = 'FastTracker .xm...'
            OnClick = btnTrkExportXmClick
          end
          object mnuTrkExportMptm: TMenuItem
            Caption = 'OpenMPT .mptm...'
            OnClick = btnTrkExportMptmClick
          end
        end
        object mnuTrkExportFilesSep: TMenuItem
          Caption = '-'
        end
        object mnuTrkExportRegion: TMenuItem
          Caption = 'Export Marked Region to Timeline'
          Enabled = False
          OnClick = pmTrkExportRegionToTimelineClick
        end
        object mnuTrkExportPattern: TMenuItem
          Caption = 'Export Pattern to Timeline'
          OnClick = pmTrkExportPatternToTimelineClick
        end
      end
    end
    object mnuMixer: TMenuItem
      Caption = 'Mixer'
      Visible = False
      object mnuMixMeters: TMenuItem
        Caption = 'Loudness and Phase Meters...'
        OnClick = ShowMetersClick
      end
      object mnuMixStrip: TMenuItem
        Caption = 'Strip'
        object mnuMixAddTrack: TMenuItem
          Caption = 'Add track'
          OnClick = btnMixAddTrackClick
        end
        object mnuMixAddBus: TMenuItem
          Caption = 'Add bus'
          OnClick = btnMixAddBusClick
        end
        object mnuMixAddAux: TMenuItem
          Caption = 'Add aux'
          OnClick = btnMixAddAuxClick
        end
        object mnuMixAddVCA: TMenuItem
          Caption = 'Add VCA'
          OnClick = btnMixAddVCAClick
        end
        object mnuMixRemove: TMenuItem
          Caption = 'Remove strip'
          OnClick = btnMixRemoveClick
        end
        object mnuMixApply: TMenuItem
          Caption = 'Apply strip'
          OnClick = btnMixApplyClick
        end
      end
      object mnuMixInsert: TMenuItem
        Caption = 'Insert'
        object mnuMixAddInsert: TMenuItem
          Caption = 'Add insert'
          OnClick = btnMixAddEQClick
        end
        object mnuMixLoadPlugin: TMenuItem
          Caption = 'Load plug-in (VST3 / VST2 / CLAP)...'
          OnClick = btnMixAddVSTClick
        end
        object mnuMixDelInsert: TMenuItem
          Caption = 'Remove insert'
          OnClick = btnMixDelInsertClick
        end
      end
      object mnuMixModulation: TMenuItem
        Caption = 'Modulation'
        object mnuMixModLFO: TMenuItem
          Tag = 1
          Caption = 'Add LFO modulator...'
          OnClick = MixModMenuClick
        end
        object mnuMixModRandom: TMenuItem
          Tag = 2
          Caption = 'Add smooth random modulator...'
          OnClick = MixModMenuClick
        end
        object mnuMixModSteps: TMenuItem
          Tag = 3
          Caption = 'Add step modulator...'
          OnClick = MixModMenuClick
        end
        object mnuMixModFollower: TMenuItem
          Tag = 4
          Caption = 'Add envelope follower (selected strip)'
          OnClick = MixModMenuClick
        end
        object mnuMixModMacro: TMenuItem
          Tag = 5
          Caption = 'Add macro knob...'
          OnClick = MixModMenuClick
        end
        object mnuMixModRoute: TMenuItem
          Tag = 6
          Caption = 'Route modulator to selected strip...'
          OnClick = MixModMenuClick
        end
        object mnuMixModList: TMenuItem
          Tag = 7
          Caption = 'List modulators and routes'
          OnClick = MixModMenuClick
        end
        object mnuMixModClear: TMenuItem
          Tag = 8
          Caption = 'Remove all modulators'
          OnClick = MixModMenuClick
        end
      end
      object mnuMixTools: TMenuItem
        Caption = 'Tools'
        object mnuMixPreview: TMenuItem
          Caption = 'Render preview mix'
          OnClick = btnMixPreviewClick
        end
      end
    end
    object mnuMidi: TMenuItem
      Caption = 'MIDI'
      Visible = False
      object mnuMidiClip: TMenuItem
        Caption = 'Clip'
        object mnuMidiAddClip: TMenuItem
          Caption = 'Add clip'
          OnClick = btnMidiAddClipClick
        end
        object mnuMidiAddTrack: TMenuItem
          Caption = 'Add track'
          OnClick = btnMidiAddTrackClick
        end
      end
      object mnuMidiNote: TMenuItem
        Caption = 'Note'
        object mnuMidiAddNote: TMenuItem
          Caption = 'Add note'
          OnClick = btnMidiAddNoteClick
        end
        object mnuMidiDelNote: TMenuItem
          Caption = 'Delete last note'
          OnClick = btnMidiDelNoteClick
        end
      end
      object mnuMidiGrid: TMenuItem
        Caption = 'Grid'
        object mnuMidiQuantize: TMenuItem
          Caption = 'Quantize'
          OnClick = btnMidiQuantizeClick
        end
        object mnuMidiHumanize: TMenuItem
          Caption = 'Humanize'
          OnClick = btnMidiHumanizeClick
        end
        object mnuMidiDemo: TMenuItem
          Caption = 'Fill demo phrase'
          OnClick = btnMidiDemoClick
        end
      end
      object mnuMidiTransport: TMenuItem
        Caption = 'Transport'
        object mnuMidiPlay: TMenuItem
          Caption = 'Play'
          OnClick = btnMidiPlayClick
        end
        object mnuMidiStop: TMenuItem
          Caption = 'Stop'
          OnClick = btnMidiStopClick
        end
        object mnuMidiTransportSep: TMenuItem
          Caption = '-'
        end
        object mnuMidiRecord: TMenuItem
          Caption = 'Record from MIDI device'
          OnClick = mnuMidiRecordClick
        end
        object mnuMidiPanic: TMenuItem
          Caption = 'MIDI Panic (all notes off)'
          OnClick = btnSetMidiPanicClick
        end
      end
      object mnuMidiImport: TMenuItem
        Caption = 'Import .mid...'
        OnClick = btnMidiImportSMFClick
      end
      object mnuMidiExport: TMenuItem
        Caption = 'Export .mid...'
        OnClick = btnMidiExportSMFClick
      end
    end
    object mnuTimeline: TMenuItem
      Caption = 'Timeline'
      Visible = False
      OnClick = mnuTimelineClick
      object mnuTlFoley: TMenuItem
        Caption = 'Foley Sampler...'
        OnClick = ShowFoleyClick
      end
      object mnuTlMeters: TMenuItem
        Caption = 'Loudness and Phase Meters...'
        OnClick = ShowMetersClick
      end
      object mnuTlExport: TMenuItem
        Caption = 'Export'
        object mnuTlExportWav: TMenuItem
          Caption = 'WAV...'
          OnClick = pmTlExportWavClick
        end
        object mnuTlExportMp3: TMenuItem
          Caption = 'MP3...'
          OnClick = pmTlExportMp3Click
        end
        object mnuTlExportMp4: TMenuItem
          Caption = 'MP4...'
          OnClick = pmTlExportMp4Click
        end
        object mnuTlExportMkv: TMenuItem
          Caption = 'MKV...'
          OnClick = pmTlExportMkvClick
        end
        object mnuTlExportFlac: TMenuItem
          Caption = 'FLAC...'
          OnClick = pmTlExportFlacClick
        end
      end
      object mnuTlExportSep: TMenuItem
        Caption = '-'
      end
      object mnuTlDock: TMenuItem
        Caption = 'Show Editor'
        object mnuTlDockMixer: TMenuItem
          Caption = 'Mixer'
          Tag = 0
          OnClick = DockShowClick
        end
        object mnuTlDockPiano: TMenuItem
          Caption = 'Piano roll'
          Tag = 1
          OnClick = DockShowClick
        end
        object mnuTlDockTracker: TMenuItem
          Caption = 'Tracker'
          Tag = 2
          OnClick = DockShowClick
        end
        object mnuTlDockRecord: TMenuItem
          Caption = 'Recording'
          Tag = 3
          OnClick = DockShowClick
        end
        object mnuTlDockSep: TMenuItem
          Caption = '-'
        end
        object mnuTlDockHide: TMenuItem
          Caption = 'Hide Editor'
          Tag = 9
          OnClick = DockShowClick
        end
      end
      object mnuTlBuild: TMenuItem
        Caption = 'Build'
        object mnuTlDemo: TMenuItem
          Caption = 'Build demo arrangement'
          OnClick = btnTlDemoClick
        end
        object mnuTlAddTrack: TMenuItem
          Caption = 'Add audio track'
          OnClick = btnTlAddTrackClick
        end
        object mnuTlRemoveTrack: TMenuItem
          Caption = 'Remove Timeline'
          OnClick = btnTlRemoveTrackClick
        end
      end
      object mnuTlClip: TMenuItem
        Caption = 'Clip'
        object mnuTlAddClip: TMenuItem
          Caption = 'Add clip from WAV...'
          OnClick = btnTlAddClipClick
        end
        object mnuTlSplit: TMenuItem
          Caption = 'Split at playhead'
          OnClick = btnTlSplitClick
        end
        object mnuTlDeleteClip: TMenuItem
          Caption = 'Remove Element'
          OnClick = btnTlDeleteClipClick
        end
      end
      object mnuTlImport: TMenuItem
        Caption = 'Import to Timeline'
        object mnuTlImportWav: TMenuItem
          Caption = 'WAV / PCM File...'
          OnClick = mnuTlImportWavClick
        end
        object mnuTlImportMp3: TMenuItem
          Caption = 'MP3 File...'
          OnClick = btnMp3ToTimelineClick
        end
        object mnuTlImportMp4: TMenuItem
          Caption = 'MP4 / M4A File...'
          OnClick = btnMp4ToTimelineClick
        end
        object mnuTlImportFlac: TMenuItem
          Caption = 'FLAC File...'
          OnClick = mnuTlImportFlacClick
        end
        object mnuTlImportSep1: TMenuItem
          Caption = '-'
        end
        object mnuTlImportMod: TMenuItem
          Caption = 'Tracker Module (.mod)...'
          OnClick = mnuTlImportModClick
        end
        object mnuTlImportXm: TMenuItem
          Caption = 'FastTracker II (.xm)...'
          OnClick = mnuTlImportXmClick
        end
        object mnuTlImportMptm: TMenuItem
          Caption = 'IT / MPTM (.it/.mptm)...'
          OnClick = mnuTlImportMptmClick
        end
        object mnuTlImportLegacy: TMenuItem
          Caption = 'ScreamTracker 3 (.s3m)...'
          OnClick = mnuTlImportLegacyClick
        end
        object mnuTlImportSep2: TMenuItem
          Caption = '-'
        end
        object mnuTlImportAls: TMenuItem
          Caption = 'Ableton Live Set (.als)...'
          OnClick = mnuTlImportAlsClick
        end
        object mnuTlImportFlp: TMenuItem
          Caption = 'FL Studio Project (.flp)...'
          OnClick = mnuTlImportFlpClick
        end
      end
      object mnuTlNavigation: TMenuItem
        Caption = 'Navigation'
        object mnuTlZoomIn: TMenuItem
          Caption = 'Zoom In'
          OnClick = btnTlZoomInClick
        end
        object mnuTlZoomOut: TMenuItem
          Caption = 'Zoom Out'
          OnClick = btnTlZoomOutClick
        end
        object mnuTlNavSep1: TMenuItem
          Caption = '-'
        end
        object mnuTlJumpElementStart: TMenuItem
          Caption = 'Start of Timeline'
          OnClick = pmTlJumpElementStartClick
        end
        object mnuTlJumpElementEnd: TMenuItem
          Caption = 'End of Timeline'
          OnClick = pmTlJumpElementEndClick
        end
        object mnuTlNavSep2: TMenuItem
          Caption = '-'
        end
        object mnuTlNavNext: TMenuItem
          Caption = 'Next Grid Position'
          OnClick = pmTlNavNextClick
        end
        object mnuTlNavPrev: TMenuItem
          Caption = 'Previous Grid Position'
          OnClick = pmTlNavPrevClick
        end
      end
      object mnuTlTransport: TMenuItem
        Caption = 'Transport'
        object mnuTlPlay: TMenuItem
          Caption = 'Play'
          object mnuTlPlayFromBeginning: TMenuItem
            Caption = 'Play from Beginning'
            OnClick = TlPlayFromBeginningClick
          end
          object mnuTlPlayFromCurrent: TMenuItem
            Caption = 'Play from Current'
            OnClick = TlPlayFromCurrentClick
          end
          object mnuTlPlayReverse: TMenuItem
            Caption = 'Play in Reverse'
            OnClick = TlPlayReverseClick
          end
          object mnuTlPlayPingPong: TMenuItem
            Caption = 'Play Ping Pong'
            OnClick = TlPlayPingPongClick
          end
        end
        object mnuTlStop: TMenuItem
          Caption = 'Stop'
          Enabled = False
          OnClick = btnTlStopClick
        end
      end
      object mnuTlTrack: TMenuItem
        Caption = 'Channel'
        object mnuTlTrackUp: TMenuItem
          Caption = 'Move Channel Up'
          OnClick = btnTlTrackUpClick
        end
        object mnuTlTrackDown: TMenuItem
          Caption = 'Move Channel Down'
          OnClick = btnTlTrackDownClick
        end
        object mnuTlMuteTrack: TMenuItem
          Caption = 'Mute Channel'
          OnClick = pmTlMuteTrackClick
        end
      end
      object mnuTlLoop: TMenuItem
        Caption = 'Loop'
        object mnuTlLoopStart: TMenuItem
          Caption = 'Set Loop Start Here'
          OnClick = btnTlLoopStartClick
        end
        object mnuTlLoopEnd: TMenuItem
          Caption = 'Set Loop End Here'
          OnClick = btnTlLoopEndClick
        end
        object mnuTlLoopSep1: TMenuItem
          Caption = '-'
        end
        object mnuTlLoopToggle: TMenuItem
          Caption = 'Loop Playback'
          OnClick = btnTlLoopToggleClick
        end
        object mnuTlLoopSep2: TMenuItem
          Caption = '-'
        end
        object mnuTlLoopToRange: TMenuItem
          Caption = 'Set Loop to Selection'
          OnClick = btnTlLoopToRangeClick
        end
      end
      object mnuTlBrowserSep: TMenuItem
        Caption = '-'
      end
      object mnuTlOpenBrowser: TMenuItem
        Caption = 'Open Browser Window...'
        OnClick = OpenBrowserWindowClick
      end
    end
    object mnuMp3: TMenuItem
      Caption = 'MP3'
      Visible = False
      object mnuMp3Import: TMenuItem
        Caption = 'Import MP3...'
        OnClick = btnMp3ImportClick
      end
      object mnuMp3ReadTags: TMenuItem
        Caption = 'Read tags...'
        OnClick = btnMp3ReadTagsClick
      end
      object mnuMp3ToTimeline: TMenuItem
        Caption = 'Import to timeline...'
        OnClick = btnMp3ToTimelineClick
      end
      object mnuMp3Sep1: TMenuItem
        Caption = '-'
      end
      object mnuMp3ExportTone: TMenuItem
        Caption = 'Export test tone...'
        OnClick = btnMp3ExportToneClick
      end
      object mnuMp3RoundTrip: TMenuItem
        Caption = 'Encode/decode verify'
        OnClick = btnMp3RoundTripClick
      end
      object mnuMp3Sep2: TMenuItem
        Caption = '-'
      end
      object mnuMp3Play: TMenuItem
        Caption = 'Play through engine'
        OnClick = btnMp3PlayClick
      end
      object mnuMp3Stop: TMenuItem
        Caption = 'Stop'
        OnClick = btnMp3StopClick
      end
    end
    object mnuSystem: TMenuItem
      Caption = 'System'
      Visible = False
      object mnuSystemRefresh: TMenuItem
        Caption = 'Refresh'
        OnClick = btnRefreshSystemClick
      end
      object mnuSystemOpenConfigDir: TMenuItem
        Caption = 'Open config folder'
        OnClick = btnOpenConfigDirClick
      end
      object mnuSystemOpenLogDir: TMenuItem
        Caption = 'Open log folder'
        OnClick = btnOpenLogDirClick
      end
    end
    object mnuLog: TMenuItem
      Caption = 'Log'
      object mnuShowLog: TMenuItem
        Caption = 'Open Log...'
        OnClick = ShowLogClick
      end
      object mnuApplyLevel: TMenuItem
        Caption = 'Apply level'
        OnClick = btnApplyLevelClick
      end
    end
    object mnuJobs: TMenuItem
      Caption = 'Jobs'
      Visible = False
      object mnuRunSelfTest: TMenuItem
        Caption = 'Run self-test job'
        OnClick = btnRunSelfTestClick
      end
      object mnuCancelJobs: TMenuItem
        Caption = 'Cancel all jobs'
        OnClick = btnCancelJobsClick
      end
    end
    object mnuAudio: TMenuItem
      Caption = 'Audio'
      Visible = False
      object mnuAudioStart: TMenuItem
        Caption = 'Start'
        OnClick = btnAudioStartClick
      end
      object mnuAudioStop: TMenuItem
        Caption = 'Stop'
        OnClick = btnAudioStopClick
      end
      object mnuAudioSep1: TMenuItem
        Caption = '-'
      end
      object mnuAudioTone: TMenuItem
        Caption = 'Test tone 440 Hz'
        OnClick = btnAudioToneClick
      end
      object mnuAudioReset: TMenuItem
        Caption = 'Reset device'
        OnClick = btnAudioResetClick
      end
      object mnuAudioReopen: TMenuItem
        Caption = 'Re-open from config'
        OnClick = btnAudioReopenClick
      end
    end
    object mnuDsp: TMenuItem
      Caption = 'DSP'
      Visible = False
      object mnuDspAnalyze: TMenuItem
        Caption = 'Analyze'
        OnClick = btnDspAnalyzeClick
      end
    end
    object mnuGraph: TMenuItem
      Caption = 'Graph'
      Visible = False
      object mnuGraphBuild: TMenuItem
        Caption = 'Build + analyze'
        OnClick = btnGraphBuildClick
      end
      object mnuGraphPlay: TMenuItem
        Caption = 'Play graph'
        OnClick = btnGraphPlayClick
      end
    end
    object mnuWav: TMenuItem
      Caption = 'Supported SFX'
      Visible = False
      object mnuWavImport: TMenuItem
        Caption = 'Import WAV...'
        OnClick = btnWavImportClick
      end
      object mnuWavPlay: TMenuItem
        Caption = 'Play'
        OnClick = btnWavPlayClick
      end
      object mnuWavSep1: TMenuItem
        Caption = '-'
      end
      object mnuWavExportTone: TMenuItem
        Caption = 'Export test tone...'
        OnClick = btnWavExportToneClick
      end
      object mnuWavRoundTrip: TMenuItem
        Caption = 'Round-trip verify'
        OnClick = btnWavRoundTripClick
      end
    end
    object mnuRecording: TMenuItem
      Caption = 'Recording'
      Visible = False
      object mnuRecArm: TMenuItem
        Caption = 'Start / stop live recording'
        OnClick = btnRecArmClick
      end
      object mnuRecCommit: TMenuItem
        Caption = 'Retry adding recorded take'
        OnClick = btnRecCommitClick
      end
      object mnuRecScan: TMenuItem
        Caption = 'Scan for recovery'
        OnClick = btnRecScanClick
      end
    end
    object mnuSecure: TMenuItem
      Caption = 'Secure Storage'
      Visible = False
      object mnuSecretSet: TMenuItem
        Caption = 'Set'
        OnClick = btnSecretSetClick
      end
      object mnuSecretGet: TMenuItem
        Caption = 'Get'
        OnClick = btnSecretGetClick
      end
      object mnuSecretDelete: TMenuItem
        Caption = 'Delete'
        OnClick = btnSecretDeleteClick
      end
    end
    object mnuMp4: TMenuItem
      Caption = 'MP4'
      Visible = False
      object mnuMp4Probe: TMenuItem
        Caption = 'Probe MP4...'
        OnClick = btnMp4ProbeClick
      end
      object mnuMp4Import: TMenuItem
        Caption = 'Import PCM/MP3 MP4...'
        OnClick = btnMp4ImportClick
      end
      object mnuMp4Sep1: TMenuItem
        Caption = '-'
      end
      object mnuMp4ExportTone: TMenuItem
        Caption = 'Export test tone (PCM)...'
        OnClick = btnMp4ExportToneClick
      end
      object mnuMp4RoundTrip: TMenuItem
        Caption = 'PCM encode/decode verify'
        OnClick = btnMp4RoundTripClick
      end
      object mnuMp4ToTimeline: TMenuItem
        Caption = 'Import to timeline...'
        OnClick = btnMp4ToTimelineClick
      end
      object mnuMp4Sep2: TMenuItem
        Caption = '-'
      end
      object mnuMp4Play: TMenuItem
        Caption = 'Play through engine'
        OnClick = btnMp4PlayClick
      end
      object mnuMp4Stop: TMenuItem
        Caption = 'Stop'
        OnClick = btnMp4StopClick
      end
    end
    object mnuSettings: TMenuItem
      Caption = 'Settings'
      Visible = False
      object mnuSettingsSave: TMenuItem
        Caption = 'Save settings'
        OnClick = btnSettingsSaveClick
      end
      object mnuSettingsReload: TMenuItem
        Caption = 'Reload'
        OnClick = btnSettingsReloadClick
      end
    end
    object mnuScope: TMenuItem
      Caption = 'Scope'
      Visible = False
      object mnuScopeAnalyze: TMenuItem
        Caption = 'Analyze'
        OnClick = btnScopeAnalyzeClick
      end
    end
    object mnuAdvDsp: TMenuItem
      Caption = 'Advanced DSP'
      Visible = False
      object mnuAdvDspRun: TMenuItem
        Caption = 'Run'
        OnClick = btnAdvDspRunClick
      end
    end
    object mnuAi: TMenuItem
      Caption = 'AI/SI'
      Visible = False
      object mnuAiCredentials: TMenuItem
        Caption = 'Credentials'
        object mnuAiSave: TMenuItem
          Caption = 'Save'
          OnClick = btnAiSaveClick
        end
        object mnuAiTest: TMenuItem
          Caption = 'Test'
          OnClick = btnAiTestClick
        end
        object mnuAiDelete: TMenuItem
          Caption = 'Delete'
          OnClick = btnAiDeleteClick
        end
      end
      object mnuAiMcp: TMenuItem
        Caption = 'MCP'
        object mnuAiMcpAdd: TMenuItem
          Caption = 'Add server'
          OnClick = btnAiMcpAddClick
        end
        object mnuAiMcpRemove: TMenuItem
          Caption = 'Remove server'
          OnClick = btnAiMcpRemoveClick
        end
      end
      object mnuAiChat: TMenuItem
        Caption = 'Chat'
        object mnuAiSend: TMenuItem
          Caption = 'Send'
          OnClick = btnAiSendClick
        end
        object mnuAiClear: TMenuItem
          Caption = 'Clear chat'
          OnClick = btnAiClearClick
        end
      end
      object mnuAiSuno: TMenuItem
        Caption = 'Generate with Suno'
        OnClick = btnSunoGenerateClick
      end
      object mnuAiOpenCache: TMenuItem
        Caption = 'Open Suno Cache Folder...'
        Hint = 'Generated Suno takes live here until you move them - open the folder to copy your audio somewhere safe.'
        OnClick = mnuAiOpenCacheClick
      end
      object mnuAiVoice: TMenuItem
        Caption = 'Record voice command'
        OnClick = btnVoiceRecordClick
      end
      object mnuAiMixAssist: TMenuItem
        Caption = 'Mixing Assistant'
        object mnuAiMixAnalyze: TMenuItem
          Caption = 'Analyze Mix'
          OnClick = btnAiAnalyzeMixClick
        end
        object mnuAiMixPreview: TMenuItem
          Caption = 'Preview'
          OnClick = btnAiMixPreviewClick
        end
        object mnuAiMixCompare: TMenuItem
          Caption = 'Compare'
          OnClick = btnAiMixCompareClick
        end
        object mnuAiMixApply: TMenuItem
          Caption = 'Apply'
          OnClick = btnAiMixApplyClick
        end
        object mnuAiMixReject: TMenuItem
          Caption = 'Reject'
          OnClick = btnAiMixRejectClick
        end
      end
      object mnuAiMasterAssist: TMenuItem
        Caption = 'Mastering Assistant'
        object mnuAiMasterSuggest: TMenuItem
          Caption = 'Suggest Mastering'
          OnClick = btnAiSuggestMasteringClick
        end
        object mnuAiMasterPreview: TMenuItem
          Caption = 'Preview'
          OnClick = btnAiMasterPreviewClick
        end
        object mnuAiMasterCompare: TMenuItem
          Caption = 'Compare'
          OnClick = btnAiMasterCompareClick
        end
        object mnuAiMasterApply: TMenuItem
          Caption = 'Apply'
          OnClick = btnAiMasterApplyClick
        end
        object mnuAiMasterReject: TMenuItem
          Caption = 'Reject'
          OnClick = btnAiMasterRejectClick
        end
      end
    end
    object mnuScripts: TMenuItem
      Caption = 'Scripts'
      object mnuScriptRun: TMenuItem
        Caption = 'Run Python script...'
        OnClick = mnuScriptRunClick
      end
      object mnuScriptFolder: TMenuItem
        Caption = 'Open scripts folder'
        OnClick = mnuScriptFolderClick
      end
    end
    object mnuPlugins: TMenuItem
      Caption = 'Plugins'
      OnClick = mnuPluginsClick
      object mnuPlgSep1: TMenuItem
        Caption = '-'
      end
      object mnuPlgLoadVst2: TMenuItem
        Caption = 'Load VST 2 Plug-in...'
        OnClick = mnuPlgLoadVst2Click
      end
      object mnuPlgLoadVst3: TMenuItem
        Caption = 'Load VST 3 Plug-in...'
        OnClick = mnuPlgLoadVst3Click
      end
      object mnuPySep: TMenuItem
        Caption = '-'
      end
      object mnuPyEditor: TMenuItem
        Caption = 'Open Python Editor...'
        OnClick = mnuPyEditorClick
      end
      object mnuPyNew: TMenuItem
        Caption = 'New Python Plug-in...'
        OnClick = mnuPyNewClick
      end
      object mnuPyExample: TMenuItem
        Caption = 'Open Example: Guitar Overdrive / Distortion'
        OnClick = mnuPyExampleClick
      end
      object mnuPlgRescan: TMenuItem
        Caption = 'Rescan Plug-ins'
        OnClick = mnuPlgRescanClick
      end
      object mnuPyFolder: TMenuItem
        Caption = 'Open Plug-ins Folder'
        OnClick = mnuPyFolderClick
      end
    end
    object mnuHelp: TMenuItem
      Caption = 'Help'
      object mnuHelpAbout: TMenuItem
        Caption = 'UDAW Help Centre...'
        OnClick = btnHelpAboutClick
      end
      object mnuHelpLicense: TMenuItem
        Caption = 'License and EULA (Read the Agreement)...'
        OnClick = mnuHelpLicenseClick
      end
      object mnuHelpAboutUdawSep: TMenuItem
        Caption = '-'
      end
      object mnuHelpAboutUdaw: TMenuItem
        Caption = 'About Ultimanium UDAW...'
        OnClick = btnAboutClick
      end
    end
  end
  object pmTrkGrid: TPopupMenu
    OnPopup = pmTrkGridPopup
    Left = 56
    Top = 16
    object pmTrkCut: TMenuItem
      Caption = 'Cut'
      OnClick = pmTrkCutClick
    end
    object pmTrkCopy: TMenuItem
      Caption = 'Copy'
      OnClick = pmTrkCopyClick
    end
    object pmTrkPaste: TMenuItem
      Caption = 'Paste'
      OnClick = pmTrkPasteClick
    end
    object pmTrkDelete: TMenuItem
      Caption = 'Delete'
      OnClick = pmTrkDeleteClick
    end
    object pmTrkSelectAll: TMenuItem
      Caption = 'Select pattern'
      OnClick = pmTrkSelectAllClick
    end
    object pmTrkSelectChannel: TMenuItem
      Caption = 'Select channel'
      OnClick = pmTrkSelectChannelClick
    end
    object pmTrkTranspose: TMenuItem
      Caption = 'Transpose'
      object pmTrkTransUp: TMenuItem
        Caption = 'Up a semitone'
        Tag = 1
        OnClick = pmTrkTransposeClick
      end
      object pmTrkTransDown: TMenuItem
        Caption = 'Down a semitone'
        Tag = -1
        OnClick = pmTrkTransposeClick
      end
      object pmTrkOctUp: TMenuItem
        Caption = 'Up an octave'
        Tag = 12
        OnClick = pmTrkTransposeClick
      end
      object pmTrkOctDown: TMenuItem
        Caption = 'Down an octave'
        Tag = -12
        OnClick = pmTrkTransposeClick
      end
    end
    object pmTrkEditSep: TMenuItem
      Caption = '-'
    end
    object pmTrkGridShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmTrkClearCell: TMenuItem
      Caption = 'Clear cell'
      OnClick = btnTrkClearCellClick
    end
    object pmTrkFillDemo: TMenuItem
      Caption = 'Fill demo (sine arpeggio)'
      OnClick = btnTrkFillDemoClick
    end
    object pmTrkGridSep1: TMenuItem
      Caption = '-'
    end
    object pmTrkUndo: TMenuItem
      Caption = 'Undo'
      OnClick = btnTrkUndoClick
    end
    object pmTrkRedo: TMenuItem
      Caption = 'Redo'
      OnClick = btnTrkRedoClick
    end
    object pmTrkGridSep2: TMenuItem
      Caption = '-'
    end
    object pmTrkPlay: TMenuItem
      Caption = 'Play'
      OnClick = btnTrkPlayClick
    end
    object pmTrkStop: TMenuItem
      Caption = 'Stop'
      OnClick = btnTrkStopClick
    end
    object pmTrkGridExportSep: TMenuItem
      Caption = '-'
    end
    object pmTrkGridExport: TMenuItem
      Caption = 'Export'
      object pmTrkGridExportFiles: TMenuItem
        Caption = 'Files'
        object pmTrkGridExportWav: TMenuItem
          Caption = 'WAV...'
          OnClick = pmTlExportWavClick
        end
        object pmTrkGridExportMp3: TMenuItem
          Caption = 'MP3...'
          OnClick = pmTlExportMp3Click
        end
        object pmTrkGridExportFlac: TMenuItem
          Caption = 'FLAC...'
          OnClick = pmTlExportFlacClick
        end
      end
      object pmTrkGridExportFilesSep: TMenuItem
        Caption = '-'
      end
      object pmTrkGridExportRegion: TMenuItem
        Caption = 'Export Marked Region to Timeline'
        Enabled = False
        OnClick = pmTrkExportRegionToTimelineClick
      end
      object pmTrkGridExportPattern: TMenuItem
        Caption = 'Export Pattern to Timeline'
        OnClick = pmTrkExportPatternToTimelineClick
      end
    end
  end
  object pmTrkChanFx: TPopupMenu
    Left = 128
    Top = 16
    object pmTrkChanFxEdit: TMenuItem
      Caption = 'Edit effect...'
      OnClick = pmTrkChanFxEditClick
    end
    object pmTrkChanFxReplace: TMenuItem
      Caption = 'Replace effect...'
      OnClick = pmTrkChanFxReplaceClick
    end
    object pmTrkChanFxRemove: TMenuItem
      Caption = 'Remove effect'
      OnClick = pmTrkChanFxRemoveClick
    end
  end
  object pmTrkSeq: TPopupMenu
    OnPopup = pmTrkSeqPopup
    Left = 96
    Top = 16
    object pmTrkSeqShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmTrkAddPattern: TMenuItem
      Caption = 'Add pattern'
      OnClick = btnTrkAddPatternClick
    end
    object pmTrkDelPattern: TMenuItem
      Caption = 'Remove pattern'
      OnClick = btnTrkDelPatternClick
    end
    object pmTrkSeqExportSep: TMenuItem
      Caption = '-'
    end
    object pmTrkSeqExport: TMenuItem
      Caption = 'Export'
      object pmTrkSeqExportFiles: TMenuItem
        Caption = 'Files'
        object pmTrkSeqExportWav: TMenuItem
          Caption = 'WAV...'
          OnClick = pmTlExportWavClick
        end
        object pmTrkSeqExportMp3: TMenuItem
          Caption = 'MP3...'
          OnClick = pmTlExportMp3Click
        end
        object pmTrkSeqExportFlac: TMenuItem
          Caption = 'FLAC...'
          OnClick = pmTlExportFlacClick
        end
      end
      object pmTrkSeqExportFilesSep: TMenuItem
        Caption = '-'
      end
      object pmTrkSeqExportRegion: TMenuItem
        Caption = 'Export Marked Region to Timeline'
        Enabled = False
        OnClick = pmTrkExportRegionToTimelineClick
      end
      object pmTrkSeqExportPattern: TMenuItem
        Caption = 'Export Pattern to Timeline'
        OnClick = pmTrkExportPatternToTimelineClick
      end
    end
  end
  object pmMixInsert: TPopupMenu
    Left = 168
    Top = 16
    object pmMixInsertEdit: TMenuItem
      Caption = 'Edit effect...'
      OnClick = pmMixInsertEditClick
    end
    object pmMixInsertUp: TMenuItem
      Caption = 'Move up'
      OnClick = pmMixInsertUpClick
    end
    object pmMixInsertDown: TMenuItem
      Caption = 'Move down'
      OnClick = pmMixInsertDownClick
    end
    object pmMixInsertRemove: TMenuItem
      Caption = 'Remove effect'
      OnClick = pmMixInsertRemoveClick
    end
  end
  object pmMixer: TPopupMenu
    OnPopup = pmMixerPopup
    Left = 136
    Top = 16
    object pmMixerShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmMixAddTrack: TMenuItem
      Caption = 'Add track'
      OnClick = btnMixAddTrackClick
    end
    object pmMixAddBus: TMenuItem
      Caption = 'Add bus'
      OnClick = btnMixAddBusClick
    end
    object pmMixAddAux: TMenuItem
      Caption = 'Add aux'
      OnClick = btnMixAddAuxClick
    end
    object pmMixAddVCA: TMenuItem
      Caption = 'Add VCA'
      OnClick = btnMixAddVCAClick
    end
    object pmMixSep1: TMenuItem
      Caption = '-'
    end
    object pmMixRemove: TMenuItem
      Caption = 'Remove strip'
      OnClick = btnMixRemoveClick
    end
    object pmMixApply: TMenuItem
      Caption = 'Apply strip'
      OnClick = btnMixApplyClick
    end
    object pmMixSep2: TMenuItem
      Caption = '-'
    end
    object pmMixAddInsert: TMenuItem
      Caption = 'Add insert'
      OnClick = btnMixAddEQClick
    end
    object pmMixLoadPlugin: TMenuItem
      Caption = 'Load plug-in (VST3 / VST2 / CLAP)...'
      OnClick = btnMixAddVSTClick
    end
    object pmMixDelInsert: TMenuItem
      Caption = 'Remove insert'
      OnClick = btnMixDelInsertClick
    end
    object pmMixMeters: TMenuItem
      Caption = 'Loudness and Phase Meters...'
      OnClick = ShowMetersClick
    end
    object pmMixRoleMenu: TMenuItem
      Caption = 'Apply mix role'
      object pmRoleDialogue: TMenuItem
        Tag = 1
        Caption = 'Dialogue'
        OnClick = pmMixRoleClick
      end
      object pmRoleVoiceOver: TMenuItem
        Tag = 2
        Caption = 'Voice-over'
        OnClick = pmMixRoleClick
      end
      object pmRoleMusic: TMenuItem
        Tag = 3
        Caption = 'Music'
        OnClick = pmMixRoleClick
      end
      object pmRoleSfx: TMenuItem
        Tag = 4
        Caption = 'Sound Effects'
        OnClick = pmMixRoleClick
      end
      object pmRoleAmbience: TMenuItem
        Tag = 5
        Caption = 'Ambience'
        OnClick = pmMixRoleClick
      end
      object pmRoleMaster: TMenuItem
        Tag = 6
        Caption = 'Master'
        OnClick = pmMixRoleClick
      end
    end
    object pmMixSep3: TMenuItem
      Caption = '-'
    end
    object pmMixUndo: TMenuItem
      Caption = 'Undo'
      OnClick = btnMixUndoClick
    end
    object pmMixRedo: TMenuItem
      Caption = 'Redo'
      OnClick = btnMixRedoClick
    end
    object pmMixSep4: TMenuItem
      Caption = '-'
    end
    object pmMixPreview: TMenuItem
      Caption = 'Render preview mix'
      OnClick = btnMixPreviewClick
    end
    object pmMixerExportSep: TMenuItem
      Caption = '-'
    end
    object pmMixerExport: TMenuItem
      Caption = 'Export'
      object pmMixerExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmMixerExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmMixerExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmMixerExportMkv: TMenuItem
        Caption = 'MKV...'
        OnClick = pmTlExportMkvClick
      end
      object pmMixerExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object pmPianoRoll: TPopupMenu
    Left = 176
    Top = 16
    object pmPianoRollShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmMidiAddNote: TMenuItem
      Caption = 'Add note'
      OnClick = btnMidiAddNoteClick
    end
    object pmMidiDelNote: TMenuItem
      Caption = 'Delete last note'
      OnClick = btnMidiDelNoteClick
    end
    object pmMidiQuantize: TMenuItem
      Caption = 'Quantize'
      OnClick = btnMidiQuantizeClick
    end
    object pmMidiHumanize: TMenuItem
      Caption = 'Humanize'
      OnClick = btnMidiHumanizeClick
    end
    object pmMidiDemo: TMenuItem
      Caption = 'Fill demo phrase'
      OnClick = btnMidiDemoClick
    end
    object pmMidiSep1: TMenuItem
      Caption = '-'
    end
    object pmMidiUndo: TMenuItem
      Caption = 'Undo'
      OnClick = btnMidiUndoClick
    end
    object pmMidiRedo: TMenuItem
      Caption = 'Redo'
      OnClick = btnMidiRedoClick
    end
    object pmMidiSep2: TMenuItem
      Caption = '-'
    end
    object pmMidiPlay: TMenuItem
      Caption = 'Play'
      OnClick = btnMidiPlayClick
    end
    object pmMidiStop: TMenuItem
      Caption = 'Stop'
      OnClick = btnMidiStopClick
    end
    object pmPianoRollExportSep: TMenuItem
      Caption = '-'
    end
    object pmPianoRollExport: TMenuItem
      Caption = 'Export'
      object pmPianoRollExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmPianoRollExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmPianoRollExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmPianoRollExportMkv: TMenuItem
        Caption = 'MKV...'
        OnClick = pmTlExportMkvClick
      end
      object pmPianoRollExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object pmTlStage: TPopupMenu
    OnPopup = pmTlStagePopup
    Left = 248
    Top = 72
    object pmStgLaunch: TMenuItem
      Caption = 'Launch scene'
      OnClick = pmStgLaunchClick
    end
    object pmStgSep: TMenuItem
      Caption = '-'
    end
    object pmStgAdd: TMenuItem
      Caption = 'Add scene from selection'
      OnClick = pmStgAddClick
    end
    object pmStgDelete: TMenuItem
      Caption = 'Delete scene'
      OnClick = pmStgDeleteClick
    end
    object pmStgRename: TMenuItem
      Caption = 'Rename scene...'
      OnClick = pmStgRenameClick
    end
    object pmStgSetRange: TMenuItem
      Caption = 'Set scene range to selection'
      OnClick = pmStgSetRangeClick
    end
    object pmStgSegSep: TMenuItem
      Caption = '-'
    end
    object pmStgDeleteSegment: TMenuItem
      Caption = 'Delete Segment'
      OnClick = pmStgDeleteSegmentClick
    end
    object pmStgCopySegment: TMenuItem
      Caption = 'Copy Segment'
      OnClick = pmStgCopySegmentClick
    end
    object pmStgPasteSegment: TMenuItem
      Caption = 'Paste Segment'
      OnClick = pmStgPasteSegmentClick
    end
    object pmStgLoopSep: TMenuItem
      Caption = '-'
    end
    object pmStgLooping: TMenuItem
      Caption = 'Looping'
      OnClick = pmStgLoopingClick
    end
    object pmStgContinuous: TMenuItem
      Caption = 'Continuous (keep looping after the scene)'
      OnClick = pmStgContinuousClick
    end
  end
  object pmTlMarker: TPopupMenu
    Left = 280
    Top = 72
    object pmMkDelete: TMenuItem
      Caption = 'Delete'
      OnClick = pmMkDeleteClick
    end
    object pmMkRename: TMenuItem
      Caption = 'Rename...'
      OnClick = pmMkRenameClick
    end
    object pmMkLock: TMenuItem
      Caption = 'Lock / Unlock'
      OnClick = pmMkLockClick
    end
  end
  object pmTlEffect: TPopupMenu
    OnPopup = pmTlEffectPopup
    Left = 216
    Top = 72
    object pmTlEffTitle: TMenuItem
      Caption = 'Effect'
      Enabled = False
    end
    object pmTlEffSepA: TMenuItem
      Caption = '-'
    end
    object pmTlEffEdit: TMenuItem
      Caption = 'Edit Effect...'
      Hint = 'Change this effect'#39's settings and render it again over the same region'
      OnClick = pmTlEffEditClick
    end
    object pmTlEffUndo: TMenuItem
      Caption = 'Undo Effect'
      Hint =
        'Put the original sound back over this region (from the kept orig' +
        'inal, or from the Master track when no original exists)'
      OnClick = TlUndoEffectClick
    end
  end
  object pmTimeline: TPopupMenu
    OnPopup = pmTimelinePopup
    Left = 216
    Top = 16
    object pmTlEditCat: TMenuItem
      Caption = 'Edit'
      object pmTlRedo: TMenuItem
        Caption = 'Redo'
        OnClick = btnTlRedoClick
      end
      object pmTlUndo: TMenuItem
        Caption = 'Undo'
        OnClick = btnTlUndoClick
      end
      object pmTlHistory: TMenuItem
        Caption = 'Undo/Redo History'
      end
      object pmTlSepEditA: TMenuItem
        Caption = '-'
      end
      object pmTlCopy: TMenuItem
        Caption = 'Copy'
        OnClick = btnTlCopyClick
      end
      object pmTlCut: TMenuItem
        Caption = 'Cut'
        OnClick = btnTlCutClick
      end
      object pmTlPaste: TMenuItem
        Caption = 'Paste at playhead'
        OnClick = btnTlPasteClick
      end
      object pmTlLockClip: TMenuItem
        Caption = 'Lock Clip'
        OnClick = btnTlLockClipClick
      end
      object pmTlClampTo: TMenuItem
        Caption = 'Clamp to'
        object pmTlClampLast: TMenuItem
          Tag = 1
          Caption = 'Clamp to Last Segment'
          OnClick = TlClampToClick
        end
        object pmTlClampNext: TMenuItem
          Tag = 2
          Caption = 'Clamp to Next Segment'
          OnClick = TlClampToClick
        end
      end
      object pmTlSepEditB: TMenuItem
        Caption = '-'
      end
      object pmTlCopySelection: TMenuItem
        Caption = 'Copy Selection'
        OnClick = pmTlCopySelectionClick
      end
      object pmTlCutSelection: TMenuItem
        Caption = 'Cut Selection'
        OnClick = pmTlCutSelectionClick
      end
      object pmTlPasteSelection: TMenuItem
        Caption = 'Paste Selection'
        OnClick = pmTlPasteSelectionClick
      end
      object pmTlSepEditC: TMenuItem
        Caption = '-'
      end
      object pmTlWarp: TMenuItem
        Caption = 'WARP'
        object pmTlWarpAdd: TMenuItem
          Tag = 1
          Caption = 'Add Marker at Playhead'
          OnClick = TlWarpMenuClick
        end
        object pmTlWarpApply: TMenuItem
          Tag = 4
          Caption = 'Apply Markers'
          OnClick = TlWarpMenuClick
        end
        object pmTlWarpAuto: TMenuItem
          Tag = 3
          Caption = 'Auto-Detect Beats to Grid'
          OnClick = TlWarpMenuClick
        end
        object pmTlWarpClear: TMenuItem
          Tag = 5
          Caption = 'Clear Markers'
          OnClick = TlWarpMenuClick
        end
        object pmTlClipTempo: TMenuItem
          Caption = 'Clip Tempo (BPM)...'
          OnClick = TlClipTempoClick
        end
        object pmTlWarpSnap: TMenuItem
          Tag = 2
          Caption = 'Snap Marker to Nearest Beat'
          OnClick = TlWarpMenuClick
        end
      end
      object pmTlSepEditD: TMenuItem
        Caption = '-'
      end
      object pmTlEffects: TMenuItem
        Caption = 'Audio Effects'
        object pmTlFxGrpCreative: TMenuItem
          Caption = 'Creative'
          object pmTlFxAMRadio: TMenuItem
            Tag = 89
            Caption = 'AM Radio'
            OnClick = TlFxMenuClick
          end
          object pmTlFxAutoWah: TMenuItem
            Tag = 67
            Caption = 'Auto-Wah'
            OnClick = TlFxMenuClick
          end
          object pmTlFxCombFilter: TMenuItem
            Tag = 75
            Caption = 'Comb Filter'
            OnClick = TlFxMenuClick
          end
          object pmTlFxFrequencyShifter: TMenuItem
            Tag = 66
            Caption = 'Frequency Shifter'
            OnClick = TlFxMenuClick
          end
          object pmTlFxFuzz: TMenuItem
            Tag = 90
            Caption = 'Fuzz'
            OnClick = TlFxMenuClick
          end
          object pmTlFxMegaphone: TMenuItem
            Tag = 69
            Caption = 'Megaphone'
            OnClick = TlFxMenuClick
          end
          object pmTlFxOctaveUpRectifier: TMenuItem
            Tag = 91
            Caption = 'Octave-Up Rectifier'
            OnClick = TlFxMenuClick
          end
          object pmTlFxRobotVoice: TMenuItem
            Tag = 68
            Caption = 'Robot Voice'
            OnClick = TlFxMenuClick
          end
          object pmTlFxRotarySpeaker: TMenuItem
            Tag = 73
            Caption = 'Rotary Speaker'
            OnClick = TlFxMenuClick
          end
          object pmTlFxStringEnsemble: TMenuItem
            Tag = 92
            Caption = 'String Ensemble'
            OnClick = TlFxMenuClick
          end
          object pmTlFxStutter: TMenuItem
            Tag = 95
            Caption = 'Stutter'
            OnClick = TlFxMenuClick
          end
          object pmTlFxTapeStop: TMenuItem
            Tag = 71
            Caption = 'Tape Stop'
            OnClick = TlFxMenuClick
          end
          object pmTlFxTapeWowFlutter: TMenuItem
            Tag = 88
            Caption = 'Tape Wow && Flutter'
            OnClick = TlFxMenuClick
          end
          object pmTlFxTranceGate: TMenuItem
            Tag = 72
            Caption = 'Trance Gate'
            OnClick = TlFxMenuClick
          end
          object pmTlFxUnderwater: TMenuItem
            Tag = 70
            Caption = 'Underwater'
            OnClick = TlFxMenuClick
          end
          object pmTlFxVinylCrackle: TMenuItem
            Tag = 74
            Caption = 'Vinyl Crackle'
            OnClick = TlFxMenuClick
          end
          object pmTlFxVocoder: TMenuItem
            Tag = 77
            Caption = 'Vocoder'
            OnClick = TlFxMenuClick
          end
        end
        object pmTlFxGrpTimeSpace: TMenuItem
          Caption = 'Delay && Reverb'
          object pmTlFxConvolutionReverb: TMenuItem
            Tag = 37
            Caption = 'Convolution Reverb...'
            OnClick = TlFxMenuClick
          end
          object pmTlFxDelay: TMenuItem
            Tag = 14
            Caption = 'Delay'
            OnClick = TlFxMenuClick
          end
          object pmTlFxEcho: TMenuItem
            Tag = 42
            Caption = 'Echo'
            OnClick = TlFxMenuClick
          end
          object pmTlFxHallReverb: TMenuItem
            Tag = 58
            Caption = 'Hall Reverb'
            OnClick = TlFxMenuClick
          end
          object pmTlFxMultiTapDelay: TMenuItem
            Tag = 93
            Caption = 'Multi-Tap Delay'
            OnClick = TlFxMenuClick
          end
          object pmTlFxPingPongDelay: TMenuItem
            Tag = 20
            Caption = 'Ping-Pong Delay'
            OnClick = TlFxMenuClick
          end
          object pmTlFxPlateReverb: TMenuItem
            Tag = 60
            Caption = 'Plate Reverb'
            OnClick = TlFxMenuClick
          end
          object pmTlFxReverb: TMenuItem
            Tag = 2
            Caption = 'Reverb'
            OnClick = TlFxMenuClick
          end
          object pmTlFxRoomReverb: TMenuItem
            Tag = 59
            Caption = 'Room Reverb'
            OnClick = TlFxMenuClick
          end
          object pmTlFxSlapbackDelay: TMenuItem
            Tag = 56
            Caption = 'Slapback Delay'
            OnClick = TlFxMenuClick
          end
          object pmTlFxTapeDelay: TMenuItem
            Tag = 94
            Caption = 'Tape Delay'
            OnClick = TlFxMenuClick
          end
        end
        object pmTlFxGrpDistortion: TMenuItem
          Caption = 'Distortion && Saturation'
          object pmTlFxBitCrusher: TMenuItem
            Tag = 9
            Caption = 'Bit Crusher'
            OnClick = TlFxMenuClick
          end
          object pmTlFxExciter: TMenuItem
            Tag = 24
            Caption = 'Exciter'
            OnClick = TlFxMenuClick
          end
          object pmTlFxFoldback: TMenuItem
            Tag = 16
            Caption = 'Foldback'
            OnClick = TlFxMenuClick
          end
          object pmTlFxHardClip: TMenuItem
            Tag = 18
            Caption = 'Hard Clip'
            OnClick = TlFxMenuClick
          end
          object pmTlFxLoFi: TMenuItem
            Tag = 57
            Caption = 'Lo-Fi'
            OnClick = TlFxMenuClick
          end
          object pmTlFxOversampledSaturation: TMenuItem
            Tag = 103
            Caption = 'Oversampled Saturation'
            OnClick = TlFxMenuClick
          end
          object pmTlFxSaturation: TMenuItem
            Tag = 8
            Caption = 'Saturation'
            OnClick = TlFxMenuClick
          end
          object pmTlFxSoftClip: TMenuItem
            Tag = 41
            Caption = 'Soft Clip'
            OnClick = TlFxMenuClick
          end
          object pmTlFxTube: TMenuItem
            Tag = 40
            Caption = 'Tube Saturation'
            OnClick = TlFxMenuClick
          end
        end
        object pmTlFxGrpDynamics: TMenuItem
          Caption = 'Dynamics'
          object pmTlFxCompressor: TMenuItem
            Tag = 1
            Caption = 'Compressor'
            OnClick = TlFxMenuClick
          end
          object pmTlFxDeEsser: TMenuItem
            Tag = 13
            Caption = 'De-Esser'
            OnClick = TlFxMenuClick
          end
          object pmTlFxDialogRider: TMenuItem
            Tag = 101
            Caption = 'Dialog Rider'
            OnClick = TlFxMenuClick
          end
          object pmTlFxExpander: TMenuItem
            Tag = 15
            Caption = 'Expander'
            OnClick = TlFxMenuClick
          end
          object pmTlFxGate: TMenuItem
            Tag = 17
            Caption = 'Gate'
            OnClick = TlFxMenuClick
          end
          object pmTlFxLevelRider: TMenuItem
            Tag = 100
            Caption = 'Level Rider'
            OnClick = TlFxMenuClick
          end
          object pmTlFxLimiter: TMenuItem
            Tag = 19
            Caption = 'Limiter'
            OnClick = TlFxMenuClick
          end
          object pmTlFxMultibandCompressor: TMenuItem
            Tag = 28
            Caption = 'Multiband Compressor'
            OnClick = TlFxMenuClick
          end
          object pmTlFxParallelCompression: TMenuItem
            Tag = 96
            Caption = 'Parallel Compression'
            OnClick = TlFxMenuClick
          end
          object pmTlFxTransientShaper: TMenuItem
            Tag = 33
            Caption = 'Transient Shaper'
            OnClick = TlFxMenuClick
          end
          object pmTlFxTruePeakLimiter: TMenuItem
            Tag = 102
            Caption = 'True-Peak Limiter'
            OnClick = TlFxMenuClick
          end
        end
        object pmTlFxGrpEQ: TMenuItem
          Caption = 'EQ && Filters'
          object pmTlFxBandPassFilter: TMenuItem
            Tag = 54
            Caption = 'Band-Pass Filter'
            OnClick = TlFxMenuClick
          end
          object pmTlFxBassEnhance: TMenuItem
            Tag = 22
            Caption = 'Bass Enhance'
            OnClick = TlFxMenuClick
          end
          object pmTlFxBrightenEQ: TMenuItem
            Tag = 10
            Caption = 'Brighten (EQ)'
            OnClick = TlFxMenuClick
          end
          object pmTlFxHighPassFilter: TMenuItem
            Tag = 25
            Caption = 'High-Pass Filter'
            OnClick = TlFxMenuClick
          end
          object pmTlFxLowPassFilter: TMenuItem
            Tag = 26
            Caption = 'Low-Pass Filter'
            OnClick = TlFxMenuClick
          end
          object pmTlFxNotchFilter: TMenuItem
            Tag = 29
            Caption = 'Notch Filter'
            OnClick = TlFxMenuClick
          end
          object pmTlFxPresenceBoost: TMenuItem
            Tag = 31
            Caption = 'Presence Boost'
            OnClick = TlFxMenuClick
          end
          object pmTlFxTrebleBoost: TMenuItem
            Tag = 34
            Caption = 'Treble Boost'
            OnClick = TlFxMenuClick
          end
        end
        object pmTlFxGrpModulation: TMenuItem
          Caption = 'Modulation'
          object pmTlFxAutoPan: TMenuItem
            Tag = 7
            Caption = 'Auto-Pan'
            OnClick = TlFxMenuClick
          end
          object pmTlFxChorus: TMenuItem
            Tag = 3
            Caption = 'Chorus'
            OnClick = TlFxMenuClick
          end
          object pmTlFxFlanger: TMenuItem
            Tag = 4
            Caption = 'Flanger'
            OnClick = TlFxMenuClick
          end
          object pmTlFxPhaser: TMenuItem
            Tag = 5
            Caption = 'Phaser'
            OnClick = TlFxMenuClick
          end
          object pmTlFxRingModulator: TMenuItem
            Tag = 45
            Caption = 'Ring Modulator'
            OnClick = TlFxMenuClick
          end
          object pmTlFxTremolo: TMenuItem
            Tag = 6
            Caption = 'Tremolo'
            OnClick = TlFxMenuClick
          end
          object pmTlFxVibrato: TMenuItem
            Tag = 46
            Caption = 'Vibrato'
            OnClick = TlFxMenuClick
          end
        end
        object pmTlFxGrpPitch: TMenuItem
          Caption = 'Pitch'
          object pmTlFxAutoTune: TMenuItem
            Tag = 36
            Caption = 'Auto-Tune...'
            OnClick = TlFxMenuClick
          end
          object pmTlFxPitchShift: TMenuItem
            Tag = 30
            Caption = 'Pitch Shift'
            OnClick = TlFxMenuClick
          end
        end
        object pmTlFxGrpRestore: TMenuItem
          Caption = 'Restoration'
          object pmTlFxAdaptiveNoiseReduction: TMenuItem
            Tag = 104
            Caption = 'Adaptive Noise Reduction'
            OnClick = TlFxMenuClick
          end
          object pmTlFxDCOffsetRemover: TMenuItem
            Tag = 23
            Caption = 'DC Offset Remover'
            OnClick = TlFxMenuClick
          end
          object pmTlFxDeClicker: TMenuItem
            Tag = 52
            Caption = 'De-Clicker'
            OnClick = TlFxMenuClick
          end
          object pmTlFxDeClipper: TMenuItem
            Tag = 53
            Caption = 'De-Clipper'
            OnClick = TlFxMenuClick
          end
          object pmTlFxDeHummer50: TMenuItem
            Tag = 50
            Caption = 'De-Hummer (50 Hz)'
            OnClick = TlFxMenuClick
          end
          object pmTlFxDeHummer60: TMenuItem
            Tag = 51
            Caption = 'De-Hummer (60 Hz)'
            OnClick = TlFxMenuClick
          end
          object pmTlFxDePopper: TMenuItem
            Tag = 99
            Caption = 'De-Popper (Plosive Remover)'
            OnClick = TlFxMenuClick
          end
          object pmTlFxNoiseReduction: TMenuItem
            Tag = 35
            Caption = 'Noise Reduction...'
            OnClick = TlFxMenuClick
          end
        end
        object pmTlFxGrpStereo: TMenuItem
          Caption = 'Stereo'
          object pmTlFxBalance: TMenuItem
            Tag = 21
            Caption = 'Balance'
            OnClick = TlFxMenuClick
          end
          object pmTlFxInvertPhase: TMenuItem
            Tag = 44
            Caption = 'Invert Phase'
            OnClick = TlFxMenuClick
          end
          object pmTlFxMakeMono: TMenuItem
            Tag = 27
            Caption = 'Make Mono'
            OnClick = TlFxMenuClick
          end
          object pmTlFxStereoWidener: TMenuItem
            Tag = 32
            Caption = 'Stereo Widener'
            OnClick = TlFxMenuClick
          end
          object pmTlFxSwapChannels: TMenuItem
            Tag = 43
            Caption = 'Swap Channels'
            OnClick = TlFxMenuClick
          end
        end
        object pmTlFxGrpStereoBass: TMenuItem
          Caption = 'Stereo && Bass'
          object pmTlFxHaasWidener: TMenuItem
            Tag = 85
            Caption = 'Haas Widener'
            OnClick = TlFxMenuClick
          end
          object pmTlFxHeadphoneCrossfeed: TMenuItem
            Tag = 63
            Caption = 'Headphone Crossfeed'
            OnClick = TlFxMenuClick
          end
          object pmTlFxLFEFilter: TMenuItem
            Tag = 64
            Caption = 'LFE Filter'
            OnClick = TlFxMenuClick
          end
          object pmTlFxMidSideBalance: TMenuItem
            Tag = 62
            Caption = 'Mid/Side Balance'
            OnClick = TlFxMenuClick
          end
          object pmTlFxMonoBass: TMenuItem
            Tag = 86
            Caption = 'Mono Bass'
            OnClick = TlFxMenuClick
          end
          object pmTlFxStereoFixer: TMenuItem
            Tag = 61
            Caption = 'Stereo Fixer'
            OnClick = TlFxMenuClick
          end
          object pmTlFxSubBassSynth: TMenuItem
            Tag = 65
            Caption = 'Sub Bass Synth'
            OnClick = TlFxMenuClick
          end
          object pmTlFxVocalRemover: TMenuItem
            Tag = 87
            Caption = 'Vocal Remover'
            OnClick = TlFxMenuClick
          end
        end
        object pmTlFxGrpToneFilters: TMenuItem
          Caption = 'Tone && Filters'
          object pmTlFxAutoFilter: TMenuItem
            Tag = 79
            Caption = 'Auto-Filter'
            OnClick = TlFxMenuClick
          end
          object pmTlFxTiltBrighter: TMenuItem
            Tag = 97
            Caption = 'Tilt EQ (Brighter)'
            OnClick = TlFxMenuClick
          end
          object pmTlFxTiltDarker: TMenuItem
            Tag = 98
            Caption = 'Tilt EQ (Darker)'
            OnClick = TlFxMenuClick
          end
          object pmTlFxVowelAh: TMenuItem
            Tag = 80
            Caption = 'Vowel Filter (Ah)'
            OnClick = TlFxMenuClick
          end
          object pmTlFxVowelEe: TMenuItem
            Tag = 82
            Caption = 'Vowel Filter (Ee)'
            OnClick = TlFxMenuClick
          end
          object pmTlFxVowelEh: TMenuItem
            Tag = 81
            Caption = 'Vowel Filter (Eh)'
            OnClick = TlFxMenuClick
          end
          object pmTlFxVowelOh: TMenuItem
            Tag = 83
            Caption = 'Vowel Filter (Oh)'
            OnClick = TlFxMenuClick
          end
          object pmTlFxVowelOo: TMenuItem
            Tag = 84
            Caption = 'Vowel Filter (Oo)'
            OnClick = TlFxMenuClick
          end
          object pmTlFxWahWah: TMenuItem
            Tag = 78
            Caption = 'Wah-Wah'
            OnClick = TlFxMenuClick
          end
        end
        object pmTlFxGrpVoice: TMenuItem
          Caption = 'Voice'
          object pmTlFxDialogueLeveler: TMenuItem
            Tag = 48
            Caption = 'Dialogue Leveler'
            OnClick = TlFxMenuClick
          end
          object pmTlFxMusicSeparator: TMenuItem
            Tag = 116
            Caption = 'Music Separator'
            OnClick = TlFxMenuClick
          end
          object pmTlFxTelephone: TMenuItem
            Tag = 55
            Caption = 'Telephone'
            OnClick = TlFxMenuClick
          end
          object pmTlFxVocalChannel: TMenuItem
            Tag = 47
            Caption = 'Vocal Channel'
            OnClick = TlFxMenuClick
          end
          object pmTlFxVoiceIsolation: TMenuItem
            Tag = 115
            Caption = 'Voice Isolation'
            OnClick = TlFxMenuClick
          end
        end
        object pmTlFxGrpVolume: TMenuItem
          Caption = 'Volume && Fades'
          object pmTlFxAmplify: TMenuItem
            Tag = 12
            Caption = 'Amplify'
            OnClick = TlFxMenuClick
          end
          object pmTlFxFadeIn: TMenuItem
            Caption = 'Fade In'
            OnClick = TlFxFadeInClick
          end
          object pmTlFxFadeInEqualPower: TMenuItem
            Tag = 106
            Caption = 'Fade In (Equal Power)'
            OnClick = TlFxMenuClick
          end
          object pmTlFxFadeInExponential: TMenuItem
            Tag = 107
            Caption = 'Fade In (Exponential)'
            OnClick = TlFxMenuClick
          end
          object pmTlFxFadeInLogarithmic: TMenuItem
            Tag = 108
            Caption = 'Fade In (Logarithmic)'
            OnClick = TlFxMenuClick
          end
          object pmTlFxFadeInSCurve: TMenuItem
            Tag = 105
            Caption = 'Fade In (S-Curve)'
            OnClick = TlFxMenuClick
          end
          object pmTlFxFadeOut: TMenuItem
            Caption = 'Fade Out'
            OnClick = TlFxFadeOutClick
          end
          object pmTlFxFadeOutEqualPower: TMenuItem
            Tag = 110
            Caption = 'Fade Out (Equal Power)'
            OnClick = TlFxMenuClick
          end
          object pmTlFxFadeOutExponential: TMenuItem
            Tag = 111
            Caption = 'Fade Out (Exponential)'
            OnClick = TlFxMenuClick
          end
          object pmTlFxFadeOutLogarithmic: TMenuItem
            Tag = 112
            Caption = 'Fade Out (Logarithmic)'
            OnClick = TlFxMenuClick
          end
          object pmTlFxFadeOutSCurve: TMenuItem
            Tag = 109
            Caption = 'Fade Out (S-Curve)'
            OnClick = TlFxMenuClick
          end
          object pmTlFxLoudnessNormalize: TMenuItem
            Tag = 49
            Caption = 'Loudness Normalize (-16 LUFS)'
            OnClick = TlFxMenuClick
          end
          object pmTlNormalizeRange: TMenuItem
            Caption = 'Normalize'
            OnClick = btnTlNormalizeRangeClick
          end
          object pmTlFxPeakNormalize: TMenuItem
            Tag = 76
            Caption = 'Peak Normalize'
            OnClick = TlFxMenuClick
          end
          object pmTlFxSilence: TMenuItem
            Tag = 11
            Caption = 'Silence'
            OnClick = TlFxMenuClick
          end
        end
        object pmTlFxPlugin: TMenuItem
          Caption = 'Plug-in (VST3 / VST2 / CLAP)...'
          OnClick = TlFxPluginClick
        end
        object pmTlFxSepUndo: TMenuItem
          Caption = '-'
        end
        object pmTlUndoEffect: TMenuItem
          Caption = 'Undo Effect'
          OnClick = TlUndoEffectClick
        end
      end
      object pmTlSepTools: TMenuItem
        Caption = '-'
      end
      object pmTlFxGrpTools: TMenuItem
        Caption = 'Tools'
        object pmTlFxAudioToMidi: TMenuItem
          Tag = 39
          Caption = 'Audio to MIDI...'
          OnClick = TlFxMenuClick
        end
        object pmTlFxEditLane: TMenuItem
          Caption = 'Edit Lane...'
          OnClick = TlEditLaneClick
        end
        object pmTlFxLoudnessReport: TMenuItem
          Tag = 113
          Caption = 'Loudness && Phase Report'
          OnClick = TlFxMenuClick
        end
        object pmTlReverseRange: TMenuItem
          Caption = 'Reverse'
          OnClick = btnTlReverseRangeClick
        end
        object pmTlFxSplitSpeechMusic: TMenuItem
          Tag = 114
          Caption = 'Split Speech / Music'
          OnClick = TlFxMenuClick
        end
        object pmTlFxSplitStems: TMenuItem
          Tag = 38
          Caption = 'Split Stems (Drums/Bass/Vocals/Other)'
          OnClick = TlFxMenuClick
        end
      end
      object pmTlVideoEffects: TMenuItem
        Caption = 'Video Effects'
        object pmTlVfxFilters: TMenuItem
          Caption = 'Effects'
          object pmTlVfxGrpBeauty: TMenuItem
            Caption = 'Beauty'
            object pmTlVfxSoftskin: TMenuItem
              Tag = 198
              Caption = 'Beauty (Soften Skin)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxGlamour: TMenuItem
              Tag = 199
              Caption = 'Glamour Glow'
              OnClick = TlVideoFxMenuClick
            end
          end
          object pmTlVfxGrpBlur: TMenuItem
            Caption = 'Blur'
            object pmTlVfxBlur: TMenuItem
              Tag = 23
              Caption = 'Box Blur'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxDirectionalblur: TMenuItem
              Tag = 102
              Caption = 'Directional Blur (Vertical)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxGaussian: TMenuItem
              Tag = 100
              Caption = 'Gaussian Blur'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxLensblur: TMenuItem
              Tag = 105
              Caption = 'Lens Blur'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxPixelate: TMenuItem
              Tag = 25
              Caption = 'Mosaic Blur'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxMotionblur: TMenuItem
              Tag = 101
              Caption = 'Motion Blur'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxPrismblur: TMenuItem
              Tag = 107
              Caption = 'Prism Blur'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxRadialblur: TMenuItem
              Tag = 103
              Caption = 'Radial Blur'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSoftfocus: TMenuItem
              Tag = 108
              Caption = 'Soft Focus'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxTiltshift: TMenuItem
              Tag = 106
              Caption = 'Tilt-Shift Blur'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxZoomblur: TMenuItem
              Tag = 104
              Caption = 'Zoom Blur'
              OnClick = TlVideoFxMenuClick
            end
          end
          object pmTlVfxGrpCameraMotion: TMenuItem
            Caption = 'Camera Motion'
            object pmTlVfxBounce: TMenuItem
              Tag = 216
              Caption = 'Bounce'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxDutch: TMenuItem
              Tag = 214
              Caption = 'Dutch Angle'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxEarthquake: TMenuItem
              Tag = 217
              Caption = 'Earthquake'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxHandheld: TMenuItem
              Tag = 215
              Caption = 'Handheld'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxKenburns: TMenuItem
              Tag = 213
              Caption = 'Ken Burns'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxPandown: TMenuItem
              Tag = 212
              Caption = 'Pan Down'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxPanleft: TMenuItem
              Tag = 209
              Caption = 'Pan Left'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxPanright: TMenuItem
              Tag = 210
              Caption = 'Pan Right'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxPanup: TMenuItem
              Tag = 211
              Caption = 'Pan Up'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxShake: TMenuItem
              Tag = 48
              Caption = 'Shake'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSlowzoom: TMenuItem
              Tag = 49
              Caption = 'Slow Zoom In'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSlowzoomout: TMenuItem
              Tag = 208
              Caption = 'Slow Zoom Out'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSpin: TMenuItem
              Tag = 50
              Caption = 'Spin'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxPulse: TMenuItem
              Tag = 51
              Caption = 'Zoom Pulse'
              OnClick = TlVideoFxMenuClick
            end
          end
          object pmTlVfxGrpColour: TMenuItem
            Caption = 'Colour'
            object pmTlVfxAutolevels: TMenuItem
              Tag = 119
              Caption = 'Auto Levels'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxBw: TMenuItem
              Tag = 26
              Caption = 'Black and White'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxBleach: TMenuItem
              Tag = 124
              Caption = 'Bleach Bypass'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxBrighten: TMenuItem
              Tag = 33
              Caption = 'Brighten'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxWhitebalance: TMenuItem
              Tag = 120
              Caption = 'Chromatic Adaptation (Auto White Balance)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxColorcompress: TMenuItem
              Tag = 132
              Caption = 'Color Compressor'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxColorpalette: TMenuItem
              Tag = 135
              Caption = 'Color Palette (Retro 16)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxTint: TMenuItem
              Tag = 30
              Caption = 'Colour Tint'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxContrast: TMenuItem
              Tag = 35
              Caption = 'Contrast'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxContrastpop: TMenuItem
              Tag = 131
              Caption = 'Contrast Pop'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxCool: TMenuItem
              Tag = 32
              Caption = 'Cool'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxCrossprocess: TMenuItem
              Tag = 125
              Caption = 'Cross Process'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxCyanotype: TMenuItem
              Tag = 134
              Caption = 'Cyanotype'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxDarken: TMenuItem
              Tag = 34
              Caption = 'Darken'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxDesaturate: TMenuItem
              Tag = 37
              Caption = 'Desaturate'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxDespill: TMenuItem
              Tag = 136
              Caption = 'Despill (Green)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxDuotone: TMenuItem
              Tag = 29
              Caption = 'Duotone'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxExposure: TMenuItem
              Tag = 117
              Caption = 'Exposure'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxFalsecolor: TMenuItem
              Tag = 128
              Caption = 'False Color'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxFilmlook: TMenuItem
              Tag = 137
              Caption = 'Film Look'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxGamma: TMenuItem
              Tag = 118
              Caption = 'Gamma'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxHuecycle: TMenuItem
              Tag = 116
              Caption = 'Hue Cycle'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxHueshift: TMenuItem
              Tag = 115
              Caption = 'Hue Shift'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxInvert: TMenuItem
              Tag = 28
              Caption = 'Invert'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxMatte: TMenuItem
              Tag = 133
              Caption = 'Matte Fade'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxNightvision: TMenuItem
              Tag = 130
              Caption = 'Night Vision'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxPosterize: TMenuItem
              Tag = 38
              Caption = 'Posterize'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSepia: TMenuItem
              Tag = 27
              Caption = 'Sepia'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSolarize: TMenuItem
              Tag = 122
              Caption = 'Solarize'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSplittone: TMenuItem
              Tag = 127
              Caption = 'Split Tone'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSwaprb: TMenuItem
              Tag = 121
              Caption = 'Swap Red and Blue'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxTealorange: TMenuItem
              Tag = 126
              Caption = 'Teal and Orange'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxThermal: TMenuItem
              Tag = 129
              Caption = 'Thermal'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxThreshold: TMenuItem
              Tag = 123
              Caption = 'Threshold'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxVivid: TMenuItem
              Tag = 36
              Caption = 'Vivid'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxWarm: TMenuItem
              Tag = 31
              Caption = 'Warm'
              OnClick = TlVideoFxMenuClick
            end
          end
          object pmTlVfxGrpFade: TMenuItem
            Caption = 'Fade'
            object pmTlVfxBlurin: TMenuItem
              Tag = 98
              Caption = 'Blur In'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxBlurout: TMenuItem
              Tag = 99
              Caption = 'Blur Out'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxFadein: TMenuItem
              Tag = 20
              Caption = 'Fade In'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxFadeout: TMenuItem
              Tag = 21
              Caption = 'Fade Out'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxFlash: TMenuItem
              Tag = 22
              Caption = 'Flash'
              OnClick = TlVideoFxMenuClick
            end
          end
          object pmTlVfxGrpGenerate: TMenuItem
            Caption = 'Generate'
            object pmTlVfxBorder: TMenuItem
              Tag = 201
              Caption = 'Border'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxCheckerboard: TMenuItem
              Tag = 205
              Caption = 'Checkerboard'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxColorbars: TMenuItem
              Tag = 204
              Caption = 'Color Bars'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSolid: TMenuItem
              Tag = 206
              Caption = 'Color Generator (Solid)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxFastnoise: TMenuItem
              Tag = 207
              Caption = 'Fast Noise (Clouds)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxGradient: TMenuItem
              Tag = 202
              Caption = 'Gradient Overlay'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxGrid: TMenuItem
              Tag = 203
              Caption = 'Grid'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxLetterbox: TMenuItem
              Tag = 200
              Caption = 'Letterbox'
              OnClick = TlVideoFxMenuClick
            end
          end
          object pmTlVfxGrpGlitch: TMenuItem
            Caption = 'Glitch'
            object pmTlVfxVhs: TMenuItem
              Tag = 189
              Caption = 'Analog Damage (VHS)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxChromatic: TMenuItem
              Tag = 188
              Caption = 'Chromatic Aberration'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxBlockglitch: TMenuItem
              Tag = 190
              Caption = 'Digital Glitch'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxGlitch: TMenuItem
              Tag = 44
              Caption = 'Glitch'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxInterlace: TMenuItem
              Tag = 192
              Caption = 'Interlace Tear'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxRgbsplit: TMenuItem
              Tag = 45
              Caption = 'RGB Split'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxTvstatic: TMenuItem
              Tag = 191
              Caption = 'TV Static'
              OnClick = TlVideoFxMenuClick
            end
          end
          object pmTlVfxGrpLight: TMenuItem
            Caption = 'Light'
            object pmTlVfxStarglow: TMenuItem
              Tag = 144
              Caption = 'Aperture Diffraction (Star Glow)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxBloom: TMenuItem
              Tag = 139
              Caption = 'Bloom'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxCinematichaze: TMenuItem
              Tag = 141
              Caption = 'Cinematic Haze'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxFlicker: TMenuItem
              Tag = 148
              Caption = 'Flicker'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxGlow: TMenuItem
              Tag = 138
              Caption = 'Glow'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxHalation: TMenuItem
              Tag = 140
              Caption = 'Halation'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxLensflare: TMenuItem
              Tag = 143
              Caption = 'Lens Flare'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxLightleak: TMenuItem
              Tag = 146
              Caption = 'Light Leak'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxLightrays: TMenuItem
              Tag = 142
              Caption = 'Light Rays'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSpotlight: TMenuItem
              Tag = 145
              Caption = 'Spotlight'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxStrobe: TMenuItem
              Tag = 147
              Caption = 'Strobe'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxVignette: TMenuItem
              Tag = 39
              Caption = 'Vignette'
              OnClick = TlVideoFxMenuClick
            end
          end
          object pmTlVfxGrpRevival: TMenuItem
            Caption = 'Revival'
            object pmTlVfxDeadpixel: TMenuItem
              Tag = 195
              Caption = 'Dead Pixel Fixer'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxDeband: TMenuItem
              Tag = 196
              Caption = 'Deband'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxDehaze: TMenuItem
              Tag = 197
              Caption = 'Dehaze'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxDespeckle: TMenuItem
              Tag = 194
              Caption = 'Despeckle'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxDenoise: TMenuItem
              Tag = 193
              Caption = 'Noise Reduction'
              OnClick = TlVideoFxMenuClick
            end
          end
          object pmTlVfxGrpSharpen: TMenuItem
            Caption = 'Sharpen'
            object pmTlVfxClarity: TMenuItem
              Tag = 113
              Caption = 'Detail Recovery'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxEdgeenhance: TMenuItem
              Tag = 112
              Caption = 'Edge Enhance'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSharpen: TMenuItem
              Tag = 24
              Caption = 'Sharpen'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSharpenedge: TMenuItem
              Tag = 111
              Caption = 'Sharpen Edges'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxTexturepop: TMenuItem
              Tag = 114
              Caption = 'Texture Pop'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxUltrasharp: TMenuItem
              Tag = 110
              Caption = 'Ultra Sharpen'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxUnsharp: TMenuItem
              Tag = 109
              Caption = 'Unsharp Mask'
              OnClick = TlVideoFxMenuClick
            end
          end
          object pmTlVfxGrpStylize: TMenuItem
            Caption = 'Stylize'
            object pmTlVfxAbstraction: TMenuItem
              Tag = 156
              Caption = 'Abstraction'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxAnaglyph: TMenuItem
              Tag = 155
              Caption = 'Anaglyph 3D'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxCartoon: TMenuItem
              Tag = 151
              Caption = 'Cartoon'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxDither: TMenuItem
              Tag = 158
              Caption = 'Dither (Retro)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxEdgedetect: TMenuItem
              Tag = 149
              Caption = 'Edge Detect'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxEmboss: TMenuItem
              Tag = 43
              Caption = 'Emboss'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxGrow: TMenuItem
              Tag = 160
              Caption = 'Grow (Dilate)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxHalftone: TMenuItem
              Tag = 154
              Caption = 'Halftone'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxJpegdamage: TMenuItem
              Tag = 161
              Caption = 'JPEG Damage'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxOilpaint: TMenuItem
              Tag = 152
              Caption = 'Oil Paint'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxPencil: TMenuItem
              Tag = 150
              Caption = 'Pencil Sketch'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxShrink: TMenuItem
              Tag = 159
              Caption = 'Shrink (Erode)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSketch: TMenuItem
              Tag = 42
              Caption = 'Sketch'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxWatercolor: TMenuItem
              Tag = 153
              Caption = 'Watercolor'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxXray: TMenuItem
              Tag = 157
              Caption = 'X-Ray'
              OnClick = TlVideoFxMenuClick
            end
          end
          object pmTlVfxGrpTexture: TMenuItem
            Caption = 'Texture'
            object pmTlVfxCanvas: TMenuItem
              Tag = 165
              Caption = 'Canvas'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxNoise: TMenuItem
              Tag = 162
              Caption = 'Colour Noise'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxCrt: TMenuItem
              Tag = 166
              Caption = 'CRT Monitor'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxFilmdamage: TMenuItem
              Tag = 163
              Caption = 'Film Damage'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxGrain: TMenuItem
              Tag = 40
              Caption = 'Film Grain'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxOldfilm: TMenuItem
              Tag = 164
              Caption = 'Old Film'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxScanlines: TMenuItem
              Tag = 41
              Caption = 'Scanlines'
              OnClick = TlVideoFxMenuClick
            end
          end
          object pmTlVfxGrpTransform: TMenuItem
            Caption = 'Transform'
            object pmTlVfxZoomcrop: TMenuItem
              Tag = 175
              Caption = 'Crop and Zoom'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxFliph: TMenuItem
              Tag = 167
              Caption = 'Flip Horizontal'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxFlipv: TMenuItem
              Tag = 47
              Caption = 'Flip Vertical'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxKaleido: TMenuItem
              Tag = 170
              Caption = 'Kaleidoscope'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxKeystone: TMenuItem
              Tag = 176
              Caption = 'Keystone'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxMirror4: TMenuItem
              Tag = 169
              Caption = 'Mirror (Four Way)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxMirror: TMenuItem
              Tag = 46
              Caption = 'Mirror (Left to Right)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxMirrorv: TMenuItem
              Tag = 168
              Caption = 'Mirror (Top to Bottom)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxRot180: TMenuItem
              Tag = 173
              Caption = 'Rotate 180'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxRot90: TMenuItem
              Tag = 172
              Caption = 'Rotate 90 Clockwise'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxRot270: TMenuItem
              Tag = 174
              Caption = 'Rotate 90 Counter-Clockwise'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxTile: TMenuItem
              Tag = 171
              Caption = 'Tile'
              OnClick = TlVideoFxMenuClick
            end
          end
          object pmTlVfxGrpWarp: TMenuItem
            Caption = 'Warp'
            object pmTlVfxBulge: TMenuItem
              Tag = 177
              Caption = 'Bulge'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxPinch: TMenuItem
              Tag = 178
              Caption = 'Dent (Pinch)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxFisheye: TMenuItem
              Tag = 180
              Caption = 'Fisheye'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxHeathaze: TMenuItem
              Tag = 186
              Caption = 'Heat Haze'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxBarrel: TMenuItem
              Tag = 179
              Caption = 'Lens Distortion'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxMagnify: TMenuItem
              Tag = 185
              Caption = 'Magnify'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxRipple: TMenuItem
              Tag = 183
              Caption = 'Ripple'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSwirl: TMenuItem
              Tag = 181
              Caption = 'Swirl'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxUnderwater: TMenuItem
              Tag = 187
              Caption = 'Underwater'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxVortex: TMenuItem
              Tag = 182
              Caption = 'Vortex'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxWave: TMenuItem
              Tag = 184
              Caption = 'Waviness'
              OnClick = TlVideoFxMenuClick
            end
          end
        end
        object pmTlVfxTransitions: TMenuItem
          Caption = 'Transitions'
          object pmTlVfxGrpDissolve: TMenuItem
            Caption = 'Dissolve'
            object pmTlVfxAdditive: TMenuItem
              Tag = 52
              Caption = 'Additive Dissolve'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxBlurdissolve: TMenuItem
              Tag = 3
              Caption = 'Blur Dissolve'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxBurnaway: TMenuItem
              Tag = 55
              Caption = 'Burn Away'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxCrossfade: TMenuItem
              Tag = 0
              Caption = 'Cross Dissolve'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxDipblack: TMenuItem
              Tag = 1
              Caption = 'Dip to Black'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxDipwhite: TMenuItem
              Tag = 2
              Caption = 'Dip to White'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxDitherdissolve: TMenuItem
              Tag = 54
              Caption = 'Dither Dissolve'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxNonadditive: TMenuItem
              Tag = 53
              Caption = 'Non-Additive Dissolve'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxPixeldissolve: TMenuItem
              Tag = 4
              Caption = 'Pixelate Dissolve'
              OnClick = TlVideoFxMenuClick
            end
          end
          object pmTlVfxGrpIris: TMenuItem
            Caption = 'Iris'
            object pmTlVfxIriscross: TMenuItem
              Tag = 59
              Caption = 'Cross Iris'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxIrisdiamond: TMenuItem
              Tag = 57
              Caption = 'Diamond Iris'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxCircleclose: TMenuItem
              Tag = 12
              Caption = 'Iris Close'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxCircleopen: TMenuItem
              Tag = 11
              Caption = 'Iris Open'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxIrisoval: TMenuItem
              Tag = 58
              Caption = 'Oval Iris'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxIrisbox: TMenuItem
              Tag = 56
              Caption = 'Square Iris'
              OnClick = TlVideoFxMenuClick
            end
          end
          object pmTlVfxGrpMotion: TMenuItem
            Caption = 'Motion'
            object pmTlVfxBandslide: TMenuItem
              Tag = 97
              Caption = 'Band Slide'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxCardflipx: TMenuItem
              Tag = 90
              Caption = 'Card Flip (Horizontal)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxCardflipy: TMenuItem
              Tag = 91
              Caption = 'Card Flip (Vertical)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxGlitchtrans: TMenuItem
              Tag = 19
              Caption = 'Glitch Transition'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSlidedown: TMenuItem
              Tag = 16
              Caption = 'Push Down'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSlideleft: TMenuItem
              Tag = 13
              Caption = 'Push Left'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSlideright: TMenuItem
              Tag = 14
              Caption = 'Push Right'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSlideup: TMenuItem
              Tag = 15
              Caption = 'Push Up'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxRippletrans: TMenuItem
              Tag = 94
              Caption = 'Ripple Dissolve'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxCoverdown: TMenuItem
              Tag = 85
              Caption = 'Slide Down'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxCoverleft: TMenuItem
              Tag = 82
              Caption = 'Slide Left'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxCoverright: TMenuItem
              Tag = 83
              Caption = 'Slide Right'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxCoverup: TMenuItem
              Tag = 84
              Caption = 'Slide Up'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSpintrans: TMenuItem
              Tag = 92
              Caption = 'Spin Dissolve'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSplith: TMenuItem
              Tag = 86
              Caption = 'Split Open (Horizontal)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSplitv: TMenuItem
              Tag = 87
              Caption = 'Split Open (Vertical)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSqueezeh: TMenuItem
              Tag = 88
              Caption = 'Squeeze (Horizontal)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSqueezev: TMenuItem
              Tag = 89
              Caption = 'Squeeze (Vertical)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSwirltrans: TMenuItem
              Tag = 95
              Caption = 'Swirl Dissolve'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxWhippan: TMenuItem
              Tag = 93
              Caption = 'Whip Pan'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxZoomblurtrans: TMenuItem
              Tag = 96
              Caption = 'Zoom Blur Dissolve'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxZoomin: TMenuItem
              Tag = 17
              Caption = 'Zoom In'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxZoomout: TMenuItem
              Tag = 18
              Caption = 'Zoom Out'
              OnClick = TlVideoFxMenuClick
            end
          end
          object pmTlVfxGrpShape: TMenuItem
            Caption = 'Shape'
            object pmTlVfxShapeheart: TMenuItem
              Tag = 60
              Caption = 'Heart'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxShapehexagon: TMenuItem
              Tag = 67
              Caption = 'Hexagon'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxShapepentagon: TMenuItem
              Tag = 66
              Caption = 'Pentagon'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxShapestar: TMenuItem
              Tag = 61
              Caption = 'Star'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxShapetridown: TMenuItem
              Tag = 63
              Caption = 'Triangle Down'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxShapetrileft: TMenuItem
              Tag = 64
              Caption = 'Triangle Left'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxShapetriright: TMenuItem
              Tag = 65
              Caption = 'Triangle Right'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxShapetriup: TMenuItem
              Tag = 62
              Caption = 'Triangle Up'
              OnClick = TlVideoFxMenuClick
            end
          end
          object pmTlVfxGrpWipe: TMenuItem
            Caption = 'Wipe'
            object pmTlVfxBandwipe: TMenuItem
              Tag = 68
              Caption = 'Band Wipe'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxBarndoor: TMenuItem
              Tag = 10
              Caption = 'Barn Doors'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxCheckerwipe: TMenuItem
              Tag = 71
              Caption = 'Checker Wipe'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxClock: TMenuItem
              Tag = 9
              Caption = 'Clock Wipe'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxDiagwipe: TMenuItem
              Tag = 72
              Caption = 'Diagonal Wipe (Top Left)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxDiagwipe2: TMenuItem
              Tag = 73
              Caption = 'Diagonal Wipe (Top Right)'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxFanwipe: TMenuItem
              Tag = 75
              Caption = 'Fan Wipe'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxInsetwipe: TMenuItem
              Tag = 80
              Caption = 'Inset Wipe'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxLumawipe: TMenuItem
              Tag = 81
              Caption = 'Luma Wipe'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxPinwheel: TMenuItem
              Tag = 74
              Caption = 'Pinwheel'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxBlockwipe: TMenuItem
              Tag = 79
              Caption = 'Random Blocks'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxSpiralwipe: TMenuItem
              Tag = 76
              Caption = 'Spiral Wipe'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxVenetian: TMenuItem
              Tag = 69
              Caption = 'Venetian Blinds'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxVenetianv: TMenuItem
              Tag = 70
              Caption = 'Vertical Blinds'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxWipedown: TMenuItem
              Tag = 8
              Caption = 'Wipe Down'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxWipeleft: TMenuItem
              Tag = 5
              Caption = 'Wipe Left'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxWiperight: TMenuItem
              Tag = 6
              Caption = 'Wipe Right'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxWipeup: TMenuItem
              Tag = 7
              Caption = 'Wipe Up'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxXwipe: TMenuItem
              Tag = 78
              Caption = 'X Wipe'
              OnClick = TlVideoFxMenuClick
            end
            object pmTlVfxZigzagwipe: TMenuItem
              Tag = 77
              Caption = 'Zig-Zag Wipe'
              OnClick = TlVideoFxMenuClick
            end
          end
        end
        object pmTlVfxSep: TMenuItem
          Caption = '-'
        end
        object pmTlVfxRemove: TMenuItem
          Caption = 'Remove Video Effect at Playhead'
          OnClick = TlVideoFxRemoveClick
        end
      end
      object pmTlSepEditE: TMenuItem
        Caption = '-'
      end
      object pmTlSaveSelFlac: TMenuItem
        Tag = 6
        Caption = 'Save Selection as FLAC...'
        OnClick = TlSaveSelectionClick
      end
      object pmTlSaveSelPcm: TMenuItem
        Tag = 5
        Caption = 'Save Selection as PCM...'
        OnClick = TlSaveSelectionClick
      end
      object pmTlSaveSelWav: TMenuItem
        Tag = 1
        Caption = 'Save Selection as WAV...'
        OnClick = TlSaveSelectionClick
      end
    end
    object pmTlTimelineCat: TMenuItem
      Caption = 'Timeline'
      object pmTlAddTrack: TMenuItem
        Caption = 'Add Timeline'
        OnClick = btnTlAddTrackClick
      end
      object pmTlRemoveTrack: TMenuItem
        Caption = 'Remove Timeline'
        OnClick = btnTlRemoveTrackClick
      end
      object pmTlSepChanA: TMenuItem
        Caption = '-'
      end
      object pmTlTrackDown: TMenuItem
        Caption = 'Move Channel Down'
        OnClick = btnTlTrackDownClick
      end
      object pmTlTrackUp: TMenuItem
        Caption = 'Move Channel Up'
        OnClick = btnTlTrackUpClick
      end
      object pmTlMuteTrack: TMenuItem
        Caption = 'Mute Channel'
        OnClick = pmTlMuteTrackClick
      end
      object pmTlRenameTrack: TMenuItem
        Caption = 'Rename Channel...'
        OnClick = pmTlRenameTrackClick
      end
      object pmTlCreateScore: TMenuItem
        Caption = 'Create to Score'
        OnClick = pmTlCreateScoreClick
      end
      object pmTlSepChanB: TMenuItem
        Caption = '-'
      end
      object pmTlAddClip: TMenuItem
        Caption = 'Add clip from WAV...'
        OnClick = btnTlAddClipClick
      end
      object pmTlDeleteClip: TMenuItem
        Caption = 'Remove Element'
        OnClick = btnTlDeleteClipClick
      end
      object pmTlSplit: TMenuItem
        Caption = 'Split at playhead'
        OnClick = btnTlSplitClick
      end
      object pmTlSepChanC: TMenuItem
        Caption = '-'
      end
      object pmTlNavigation: TMenuItem
        Caption = 'Navigation'
        object pmTlZoomIn: TMenuItem
          Caption = 'Zoom In'
          OnClick = btnTlZoomInClick
        end
        object pmTlZoomOut: TMenuItem
          Caption = 'Zoom Out'
          OnClick = btnTlZoomOutClick
        end
        object pmTlNavSep1: TMenuItem
          Caption = '-'
        end
        object pmTlJumpElementEnd: TMenuItem
          Caption = 'End of Timeline'
          OnClick = pmTlJumpElementEndClick
        end
        object pmTlJumpElementStart: TMenuItem
          Caption = 'Start of Timeline'
          OnClick = pmTlJumpElementStartClick
        end
        object pmTlNavSep2: TMenuItem
          Caption = '-'
        end
        object pmTlNavNext: TMenuItem
          Caption = 'Next Grid Position'
          OnClick = pmTlNavNextClick
        end
        object pmTlNavPrev: TMenuItem
          Caption = 'Previous Grid Position'
          OnClick = pmTlNavPrevClick
        end
      end
      object pmTlSepChanE: TMenuItem
        Caption = '-'
      end
      object pmTlLoop: TMenuItem
        Caption = 'Loop'
        object pmTlLoopToggle: TMenuItem
          Caption = 'Loop Playback'
          OnClick = btnTlLoopToggleClick
        end
        object pmTlLoopEnd: TMenuItem
          Caption = 'Set Loop End Here'
          OnClick = btnTlLoopEndClick
        end
        object pmTlLoopStart: TMenuItem
          Caption = 'Set Loop Start Here'
          OnClick = btnTlLoopStartClick
        end
        object pmTlLoopSep1: TMenuItem
          Caption = '-'
        end
        object pmTlLoopToRange: TMenuItem
          Caption = 'Set Loop to Selection'
          OnClick = btnTlLoopToRangeClick
        end
      end
      object pmTlPlay: TMenuItem
        Caption = 'Play'
        object pmTlPlayFromBeginning: TMenuItem
          Caption = 'Play from Beginning'
          OnClick = TlPlayFromBeginningClick
        end
        object pmTlPlayFromCurrent: TMenuItem
          Caption = 'Play from Current'
          OnClick = TlPlayFromCurrentClick
        end
        object pmTlPlayReverse: TMenuItem
          Caption = 'Play in Reverse'
          OnClick = TlPlayReverseClick
        end
        object pmTlPlayPingPong: TMenuItem
          Caption = 'Play Ping Pong'
          OnClick = TlPlayPingPongClick
        end
      end
      object pmTlStop: TMenuItem
        Caption = 'Stop'
        Enabled = False
        OnClick = btnTlStopClick
      end
      object pmTlSepChanF: TMenuItem
        Caption = '-'
      end
      object pmTlExport: TMenuItem
        Caption = 'Export'
        object pmTlExportFlac: TMenuItem
          Caption = 'FLAC...'
          OnClick = pmTlExportFlacClick
        end
        object pmTlExportMkv: TMenuItem
          Caption = 'MKV...'
          OnClick = pmTlExportMkvClick
        end
        object pmTlExportMp3: TMenuItem
          Caption = 'MP3...'
          OnClick = pmTlExportMp3Click
        end
        object pmTlExportMp4: TMenuItem
          Caption = 'MP4...'
          OnClick = pmTlExportMp4Click
        end
        object pmTlExportWav: TMenuItem
          Caption = 'WAV...'
          OnClick = pmTlExportWavClick
        end
      end
      object pmTlImport: TMenuItem
        Caption = 'Import to Timeline'
        object pmTlImportFlac: TMenuItem
          Caption = 'FLAC File...'
          OnClick = mnuTlImportFlacClick
        end
        object pmTlImportMp3: TMenuItem
          Caption = 'MP3 File...'
          OnClick = btnMp3ToTimelineClick
        end
        object pmTlImportMp4: TMenuItem
          Caption = 'MP4 / M4A File...'
          OnClick = btnMp4ToTimelineClick
        end
        object pmTlImportWav: TMenuItem
          Caption = 'WAV / PCM File...'
          OnClick = mnuTlImportWavClick
        end
        object pmTlImportSep1: TMenuItem
          Caption = '-'
        end
        object pmTlImportXm: TMenuItem
          Caption = 'FastTracker II (.xm)...'
          OnClick = mnuTlImportXmClick
        end
        object pmTlImportMptm: TMenuItem
          Caption = 'IT / MPTM (.it/.mptm)...'
          OnClick = mnuTlImportMptmClick
        end
        object pmTlImportLegacy: TMenuItem
          Caption = 'ScreamTracker 3 (.s3m)...'
          OnClick = mnuTlImportLegacyClick
        end
        object pmTlImportMod: TMenuItem
          Caption = 'Tracker Module (.mod)...'
          OnClick = mnuTlImportModClick
        end
        object pmTlImportSep2: TMenuItem
          Caption = '-'
        end
        object pmTlImportAls: TMenuItem
          Caption = 'Ableton Live Set (.als)...'
          OnClick = mnuTlImportAlsClick
        end
        object pmTlImportFlp: TMenuItem
          Caption = 'FL Studio Project (.flp)...'
          OnClick = mnuTlImportFlpClick
        end
      end
      object pmTlSepChanG: TMenuItem
        Caption = '-'
      end
      object pmTimelineOpenBrowser: TMenuItem
        Caption = 'Open Browser Window...'
        OnClick = OpenBrowserWindowClick
      end
      object pmTimelineShowLog: TMenuItem
        Caption = 'Open Log...'
        OnClick = ShowLogClick
      end
    end
  end
  object pmTimelineRuler: TPopupMenu
    OnPopup = pmTimelineRulerPopup
    Left = 216
    Top = 56
    object pmTlrAddMarker: TMenuItem
      Caption = 'Add Marker Here...'
      OnClick = btnTlAddMarkerHereClick
    end
    object pmTlrLoop: TMenuItem
      Caption = 'Loop'
      object pmTlrLoopEnabled: TMenuItem
        Caption = 'Loop Playback'
        OnClick = btnTlLoopToggleClick
      end
      object pmTlrLoopEnd: TMenuItem
        Caption = 'Set Loop End Here'
        OnClick = btnTlLoopEndClick
      end
      object pmTlrLoopStart: TMenuItem
        Caption = 'Set Loop Start Here'
        OnClick = btnTlLoopStartClick
      end
      object pmTlrLoopSep1: TMenuItem
        Caption = '-'
      end
      object pmTlrLoopToRange: TMenuItem
        Caption = 'Set Loop to Selection'
        OnClick = btnTlLoopToRangeClick
      end
    end
    object pmTimelineRulerShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmTlrSepRange: TMenuItem
      Caption = '-'
    end
    object pmTlrCopyRange: TMenuItem
      Caption = 'Copy Range'
      OnClick = pmTlCopySelectionClick
    end
    object pmTlrCutRange: TMenuItem
      Caption = 'Cut Range'
      OnClick = pmTlCutSelectionClick
    end
    object pmTlrDeleteRange: TMenuItem
      Caption = 'Delete Range'
      OnClick = btnTlDeleteRangeClick
    end
    object pmTlrFadeInRange: TMenuItem
      Caption = 'Fade In Range'
      OnClick = btnTlFadeInRangeClick
    end
    object pmTlrFadeOutRange: TMenuItem
      Caption = 'Fade Out Range'
      OnClick = btnTlFadeOutRangeClick
    end
    object pmTlrPasteRange: TMenuItem
      Caption = 'Paste Range at Playhead'
      OnClick = pmTlPasteSelectionClick
    end
    object pmTlrSplitRange: TMenuItem
      Caption = 'Split Clips at Range Edges'
      OnClick = btnTlSplitRangeClick
    end
    object pmTlrSep1: TMenuItem
      Caption = '-'
    end
    object pmTlrGoEnd: TMenuItem
      Caption = 'Go to End'
      OnClick = btnTlGoEndClick
    end
    object pmTlrGoStart: TMenuItem
      Caption = 'Go to Start'
      OnClick = btnTlGoStartClick
    end
    object pmTlrSep2: TMenuItem
      Caption = '-'
    end
    object pmTlrZoomIn: TMenuItem
      Caption = 'Zoom In'
      OnClick = btnTlZoomInClick
    end
    object pmTlrZoomOut: TMenuItem
      Caption = 'Zoom Out'
      OnClick = btnTlZoomOutClick
    end
    object pmTlrZoomFit: TMenuItem
      Caption = 'Zoom to Fit'
      OnClick = btnTlZoomFitClick
    end
    object pmTlrSep3: TMenuItem
      Caption = '-'
    end
    object pmTlrPlay: TMenuItem
      Caption = 'Play'
      OnClick = btnTlPlayClick
    end
    object pmTlrStop: TMenuItem
      Caption = 'Stop'
      Enabled = False
      OnClick = btnTlStopClick
    end
    object pmTlrSep4: TMenuItem
      Caption = '-'
    end
    object pmTlrRedo: TMenuItem
      Caption = 'Redo'
      OnClick = btnTlRedoClick
    end
    object pmTlrUndo: TMenuItem
      Caption = 'Undo'
      OnClick = btnTlUndoClick
    end
    object pmTlrHistory: TMenuItem
      Caption = 'Undo/Redo History'
    end
    object pmTimelineRulerExportSep: TMenuItem
      Caption = '-'
    end
    object pmTimelineRulerExport: TMenuItem
      Caption = 'Export'
      object pmTimelineRulerExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
      object pmTimelineRulerExportMkv: TMenuItem
        Caption = 'MKV...'
        OnClick = pmTlExportMkvClick
      end
      object pmTimelineRulerExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmTimelineRulerExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmTimelineRulerExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
    end
  end
  object pmProject: TPopupMenu
    Left = 256
    Top = 16
    object pmProjectShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmProjectNew: TMenuItem
      Caption = 'New'
      OnClick = btnProjectNewClick
    end
    object pmProjectOpen: TMenuItem
      Caption = 'Open...'
      OnClick = btnProjectOpenClick
    end
    object pmProjectSave: TMenuItem
      Caption = 'Save'
      OnClick = btnProjectSaveClick
    end
    object pmProjectSaveAs: TMenuItem
      Caption = 'Save As...'
      OnClick = btnProjectSaveAsClick
    end
    object pmProjectSep1: TMenuItem
      Caption = '-'
    end
    object pmProjectApply: TMenuItem
      Caption = 'Apply metadata'
      OnClick = btnProjectApplyClick
    end
    object pmProjectSep2: TMenuItem
      Caption = '-'
    end
    object pmProjectUndo: TMenuItem
      Caption = 'Undo'
      OnClick = btnUndoClick
    end
    object pmProjectRedo: TMenuItem
      Caption = 'Redo'
      OnClick = btnRedoClick
    end
    object pmProjectSep3: TMenuItem
      Caption = '-'
    end
    object pmProjectAddGainNode: TMenuItem
      Caption = 'Add gain node'
      OnClick = btnAddGainNodeClick
    end
    object pmProjectRemoveLastNode: TMenuItem
      Caption = 'Remove last node'
      OnClick = btnRemoveLastNodeClick
    end
    object pmProjectSep4: TMenuItem
      Caption = '-'
    end
    object pmProjectAutosaveNow: TMenuItem
      Caption = 'Autosave now'
      OnClick = btnAutosaveNowClick
    end
    object pmProjectRecover: TMenuItem
      Caption = 'Recover unsaved changes'
      OnClick = btnRecoverClick
    end
    object pmProjectExportSep: TMenuItem
      Caption = '-'
    end
    object pmProjectExport: TMenuItem
      Caption = 'Export'
      object pmProjectExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmProjectExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmProjectExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmProjectExportMkv: TMenuItem
        Caption = 'MKV...'
        OnClick = pmTlExportMkvClick
      end
      object pmProjectExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object pmMp3: TPopupMenu
    Left = 296
    Top = 16
    object pmMp3ShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmMp3Import: TMenuItem
      Caption = 'Import MP3...'
      OnClick = btnMp3ImportClick
    end
    object pmMp3ReadTags: TMenuItem
      Caption = 'Read tags...'
      OnClick = btnMp3ReadTagsClick
    end
    object pmMp3ToTimeline: TMenuItem
      Caption = 'Import to timeline...'
      OnClick = btnMp3ToTimelineClick
    end
    object pmMp3Sep1: TMenuItem
      Caption = '-'
    end
    object pmMp3ExportTone: TMenuItem
      Caption = 'Export test tone...'
      OnClick = btnMp3ExportToneClick
    end
    object pmMp3RoundTrip: TMenuItem
      Caption = 'Encode/decode verify'
      OnClick = btnMp3RoundTripClick
    end
    object pmMp3Sep2: TMenuItem
      Caption = '-'
    end
    object pmMp3Play: TMenuItem
      Caption = 'Play through engine'
      OnClick = btnMp3PlayClick
    end
    object pmMp3Stop: TMenuItem
      Caption = 'Stop'
      OnClick = btnMp3StopClick
    end
    object pmMp3ExportSep: TMenuItem
      Caption = '-'
    end
    object pmMp3Export: TMenuItem
      Caption = 'Export'
      object pmMp3ExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmMp3ExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmMp3ExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmMp3ExportMkv: TMenuItem
        Caption = 'MKV...'
        OnClick = pmTlExportMkvClick
      end
      object pmMp3ExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object pmSystem: TPopupMenu
    Left = 336
    Top = 16
    object pmSystemShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmSystemRefresh: TMenuItem
      Caption = 'Refresh'
      OnClick = btnRefreshSystemClick
    end
    object pmSystemOpenConfigDir: TMenuItem
      Caption = 'Open config folder'
      OnClick = btnOpenConfigDirClick
    end
    object pmSystemOpenLogDir: TMenuItem
      Caption = 'Open log folder'
      OnClick = btnOpenLogDirClick
    end
    object pmSystemExportSep: TMenuItem
      Caption = '-'
    end
    object pmSystemExport: TMenuItem
      Caption = 'Export'
      object pmSystemExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmSystemExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmSystemExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmSystemExportMkv: TMenuItem
        Caption = 'MKV...'
        OnClick = pmTlExportMkvClick
      end
      object pmSystemExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object pmJobs: TPopupMenu
    Left = 416
    Top = 16
    object pmJobsShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmRunSelfTest: TMenuItem
      Caption = 'Run self-test job'
      OnClick = btnRunSelfTestClick
    end
    object pmCancelJobs: TMenuItem
      Caption = 'Cancel all jobs'
      OnClick = btnCancelJobsClick
    end
    object pmJobsExportSep: TMenuItem
      Caption = '-'
    end
    object pmJobsExport: TMenuItem
      Caption = 'Export'
      object pmJobsExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmJobsExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmJobsExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmJobsExportMkv: TMenuItem
        Caption = 'MKV...'
        OnClick = pmTlExportMkvClick
      end
      object pmJobsExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object pmAudio: TPopupMenu
    Left = 456
    Top = 16
    object pmAudioShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmAudioStart: TMenuItem
      Caption = 'Start'
      OnClick = btnAudioStartClick
    end
    object pmAudioStop: TMenuItem
      Caption = 'Stop'
      OnClick = btnAudioStopClick
    end
    object pmAudioSep1: TMenuItem
      Caption = '-'
    end
    object pmAudioTone: TMenuItem
      Caption = 'Test tone 440 Hz'
      OnClick = btnAudioToneClick
    end
    object pmAudioReset: TMenuItem
      Caption = 'Reset device'
      OnClick = btnAudioResetClick
    end
    object pmAudioReopen: TMenuItem
      Caption = 'Re-open from config'
      OnClick = btnAudioReopenClick
    end
    object pmAudioExportSep: TMenuItem
      Caption = '-'
    end
    object pmAudioExport: TMenuItem
      Caption = 'Export'
      object pmAudioExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmAudioExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmAudioExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmAudioExportMkv: TMenuItem
        Caption = 'MKV...'
        OnClick = pmTlExportMkvClick
      end
      object pmAudioExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object pmDsp: TPopupMenu
    Left = 496
    Top = 16
    object pmDspShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmDspAnalyze: TMenuItem
      Caption = 'Analyze'
      OnClick = btnDspAnalyzeClick
    end
    object pmDspExportSep: TMenuItem
      Caption = '-'
    end
    object pmDspExport: TMenuItem
      Caption = 'Export'
      object pmDspExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmDspExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmDspExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmDspExportMkv: TMenuItem
        Caption = 'MKV...'
        OnClick = pmTlExportMkvClick
      end
      object pmDspExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object pmGraph: TPopupMenu
    Left = 536
    Top = 16
    object pmGraphShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmGraphBuild: TMenuItem
      Caption = 'Build + analyze'
      OnClick = btnGraphBuildClick
    end
    object pmGraphPlay: TMenuItem
      Caption = 'Play graph'
      OnClick = btnGraphPlayClick
    end
    object pmGraphExportSep: TMenuItem
      Caption = '-'
    end
    object pmGraphExport: TMenuItem
      Caption = 'Export'
      object pmGraphExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmGraphExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmGraphExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmGraphExportMkv: TMenuItem
        Caption = 'MKV...'
        OnClick = pmTlExportMkvClick
      end
      object pmGraphExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object pmWav: TPopupMenu
    Left = 576
    Top = 16
    object pmWavShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmWavImport: TMenuItem
      Caption = 'Import WAV...'
      OnClick = btnWavImportClick
    end
    object pmWavPlay: TMenuItem
      Caption = 'Play'
      OnClick = btnWavPlayClick
    end
    object pmWavSep1: TMenuItem
      Caption = '-'
    end
    object pmWavExportTone: TMenuItem
      Caption = 'Export test tone...'
      OnClick = btnWavExportToneClick
    end
    object pmWavRoundTrip: TMenuItem
      Caption = 'Round-trip verify'
      OnClick = btnWavRoundTripClick
    end
    object pmWavExportSep: TMenuItem
      Caption = '-'
    end
    object pmWavExport: TMenuItem
      Caption = 'Export'
      object pmWavExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmWavExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmWavExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmWavExportMkv: TMenuItem
        Caption = 'MKV...'
        OnClick = pmTlExportMkvClick
      end
      object pmWavExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object pmRecording: TPopupMenu
    Left = 616
    Top = 16
    object pmRecordingShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmRecArm: TMenuItem
      Caption = 'Start / stop live recording'
      OnClick = btnRecArmClick
    end
    object pmRecCommit: TMenuItem
      Caption = 'Retry adding recorded take'
      OnClick = btnRecCommitClick
    end
    object pmRecScan: TMenuItem
      Caption = 'Scan for recovery'
      OnClick = btnRecScanClick
    end
    object pmRecordingExportSep: TMenuItem
      Caption = '-'
    end
    object pmRecordingExport: TMenuItem
      Caption = 'Export'
      object pmRecordingExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmRecordingExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmRecordingExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmRecordingExportMkv: TMenuItem
        Caption = 'MKV...'
        OnClick = pmTlExportMkvClick
      end
      object pmRecordingExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object pmSecure: TPopupMenu
    Left = 656
    Top = 16
    object pmSecureShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmSecretSet: TMenuItem
      Caption = 'Set'
      OnClick = btnSecretSetClick
    end
    object pmSecretGet: TMenuItem
      Caption = 'Get'
      OnClick = btnSecretGetClick
    end
    object pmSecretDelete: TMenuItem
      Caption = 'Delete'
      OnClick = btnSecretDeleteClick
    end
    object pmSecureExportSep: TMenuItem
      Caption = '-'
    end
    object pmSecureExport: TMenuItem
      Caption = 'Export'
      object pmSecureExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmSecureExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmSecureExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmSecureExportMkv: TMenuItem
        Caption = 'MKV...'
        OnClick = pmTlExportMkvClick
      end
      object pmSecureExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object pmMp4: TPopupMenu
    Left = 696
    Top = 16
    object pmMp4ShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmMp4Probe: TMenuItem
      Caption = 'Probe MP4...'
      OnClick = btnMp4ProbeClick
    end
    object pmMp4Import: TMenuItem
      Caption = 'Import PCM/MP3 MP4...'
      OnClick = btnMp4ImportClick
    end
    object pmMp4Sep1: TMenuItem
      Caption = '-'
    end
    object pmMp4ExportTone: TMenuItem
      Caption = 'Export test tone (PCM)...'
      OnClick = btnMp4ExportToneClick
    end
    object pmMp4RoundTrip: TMenuItem
      Caption = 'PCM encode/decode verify'
      OnClick = btnMp4RoundTripClick
    end
    object pmMp4ToTimeline: TMenuItem
      Caption = 'Import to timeline...'
      OnClick = btnMp4ToTimelineClick
    end
    object pmMp4Sep2: TMenuItem
      Caption = '-'
    end
    object pmMp4Play: TMenuItem
      Caption = 'Play through engine'
      OnClick = btnMp4PlayClick
    end
    object pmMp4Stop: TMenuItem
      Caption = 'Stop'
      OnClick = btnMp4StopClick
    end
    object pmMp4ExportSep: TMenuItem
      Caption = '-'
    end
    object pmMp4Export: TMenuItem
      Caption = 'Export'
      object pmMp4ExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmMp4ExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmMp4ExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmMp4ExportMkv: TMenuItem
        Caption = 'MKV...'
        OnClick = pmTlExportMkvClick
      end
      object pmMp4ExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object pmSettings: TPopupMenu
    Left = 736
    Top = 16
    object pmSettingsShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmSettingsSave: TMenuItem
      Caption = 'Save settings'
      OnClick = btnSettingsSaveClick
    end
    object pmSettingsReload: TMenuItem
      Caption = 'Reload'
      OnClick = btnSettingsReloadClick
    end
    object pmSettingsExportSep: TMenuItem
      Caption = '-'
    end
    object pmSettingsExport: TMenuItem
      Caption = 'Export'
      object pmSettingsExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmSettingsExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmSettingsExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmSettingsExportMkv: TMenuItem
        Caption = 'MKV...'
        OnClick = pmTlExportMkvClick
      end
      object pmSettingsExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object pmScope: TPopupMenu
    Left = 776
    Top = 16
    object pmScopeShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmScopeAnalyze: TMenuItem
      Caption = 'Analyze'
      OnClick = btnScopeAnalyzeClick
    end
    object pmScopeExportSep: TMenuItem
      Caption = '-'
    end
    object pmScopeExport: TMenuItem
      Caption = 'Export'
      object pmScopeExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmScopeExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmScopeExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmScopeExportMkv: TMenuItem
        Caption = 'MKV...'
        OnClick = pmTlExportMkvClick
      end
      object pmScopeExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object pmAdvDsp: TPopupMenu
    Left = 816
    Top = 16
    object pmAdvDspShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmAdvDspRun: TMenuItem
      Caption = 'Run'
      OnClick = btnAdvDspRunClick
    end
    object pmAdvDspExportSep: TMenuItem
      Caption = '-'
    end
    object pmAdvDspExport: TMenuItem
      Caption = 'Export'
      object pmAdvDspExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmAdvDspExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmAdvDspExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmAdvDspExportMkv: TMenuItem
        Caption = 'MKV...'
        OnClick = pmTlExportMkvClick
      end
      object pmAdvDspExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object pmAi: TPopupMenu
    Left = 856
    Top = 16
    object pmAiShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmAiSave: TMenuItem
      Caption = 'Save'
      OnClick = btnAiSaveClick
    end
    object pmAiTest: TMenuItem
      Caption = 'Test'
      OnClick = btnAiTestClick
    end
    object pmAiDelete: TMenuItem
      Caption = 'Delete'
      OnClick = btnAiDeleteClick
    end
    object pmAiSep1: TMenuItem
      Caption = '-'
    end
    object pmAiMcpAdd: TMenuItem
      Caption = 'Add server'
      OnClick = btnAiMcpAddClick
    end
    object pmAiMcpRemove: TMenuItem
      Caption = 'Remove server'
      OnClick = btnAiMcpRemoveClick
    end
    object pmAiSep2: TMenuItem
      Caption = '-'
    end
    object pmAiSend: TMenuItem
      Caption = 'Send'
      OnClick = btnAiSendClick
    end
    object pmAiClear: TMenuItem
      Caption = 'Clear chat'
      OnClick = btnAiClearClick
    end
    object pmAiSep3: TMenuItem
      Caption = '-'
    end
    object pmAiSuno: TMenuItem
      Caption = 'Generate with Suno'
      OnClick = btnSunoGenerateClick
    end
    object pmAiOpenCache: TMenuItem
      Caption = 'Open Suno Cache Folder...'
      Hint = 'Generated Suno takes live here until you move them - open the folder to copy your audio somewhere safe.'
      OnClick = mnuAiOpenCacheClick
    end
    object pmAiVoice: TMenuItem
      Caption = 'Record voice command'
      OnClick = btnVoiceRecordClick
    end
    object pmAiSep4: TMenuItem
      Caption = '-'
    end
    object pmAiMixAnalyze: TMenuItem
      Caption = 'Mixing: Analyze Mix'
      OnClick = btnAiAnalyzeMixClick
    end
    object pmAiMixPreview: TMenuItem
      Caption = 'Mixing: Preview'
      OnClick = btnAiMixPreviewClick
    end
    object pmAiMixCompare: TMenuItem
      Caption = 'Mixing: Compare'
      OnClick = btnAiMixCompareClick
    end
    object pmAiMixApply: TMenuItem
      Caption = 'Mixing: Apply'
      OnClick = btnAiMixApplyClick
    end
    object pmAiMixReject: TMenuItem
      Caption = 'Mixing: Reject'
      OnClick = btnAiMixRejectClick
    end
    object pmAiSep5: TMenuItem
      Caption = '-'
    end
    object pmAiMasterSuggest: TMenuItem
      Caption = 'Mastering: Suggest'
      OnClick = btnAiSuggestMasteringClick
    end
    object pmAiMasterPreview: TMenuItem
      Caption = 'Mastering: Preview'
      OnClick = btnAiMasterPreviewClick
    end
    object pmAiMasterCompare: TMenuItem
      Caption = 'Mastering: Compare'
      OnClick = btnAiMasterCompareClick
    end
    object pmAiMasterApply: TMenuItem
      Caption = 'Mastering: Apply'
      OnClick = btnAiMasterApplyClick
    end
    object pmAiMasterReject: TMenuItem
      Caption = 'Mastering: Reject'
      OnClick = btnAiMasterRejectClick
    end
    object pmAiExportSep: TMenuItem
      Caption = '-'
    end
    object pmAiExport: TMenuItem
      Caption = 'Export'
      object pmAiExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmAiExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmAiExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmAiExportMkv: TMenuItem
        Caption = 'MKV...'
        OnClick = pmTlExportMkvClick
      end
      object pmAiExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object dlgRecSaved: TGLOpenDialog
    Filter = 'Audio files|*.wav;*.flac;*.mp3;*.mp4;*.m4a|All files|*.*'
    Options = [ofFileMustExist, ofEnableSizing]
    Title = 'Add full saved audio to timeline'
    Left = 880
    Top = 640
  end
  object dlgRecSaveTake: TGLSaveDialog
    DefaultExt = 'wav'
    Filter = 'WAV audio (*.wav)|*.wav|All files (*.*)|*.*'
    Options = [ofOverwritePrompt, ofPathMustExist, ofEnableSizing]
    Title = 'Save selected take as'
    Left = 880
    Top = 688
  end
  object memProject: TLogSink
  end
  object memTimeline: TLogSink
  end
  object memMix: TLogSink
  end
  object memMidi: TLogSink
  end
  object memTrk: TLogSink
  end
  object memRec: TLogSink
  end
  object memSysPaths: TLogSink
  end
  object memSystem: TLogSink
  end
  object memAudio: TLogSink
  end
  object memDspReadout: TLogSink
  end
  object memGraph: TLogSink
  end
  object memWav: TLogSink
  end
  object memSecure: TLogSink
  end
  object memMp3: TLogSink
  end
  object memMp4: TLogSink
  end
  object memScopeReadout: TLogSink
  end
  object memAdvDspReadout: TLogSink
  end
  object memBrowser: TLogSink
  end
  object memAiMcpProviders: TLogSink
  end
  object memAiLog: TLogSink
  end
end
