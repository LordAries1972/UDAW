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
  Menu = mnuMain
  KeyPreview = True
  OnCreate = FormCreate
  OnClose = FormClose
  OnDestroy = FormDestroy
  OnKeyDown = FormKeyDown
  OnResize = FormResize
  TextHeight = 15
  object pnlTop: TPanel
    Left = 0
    Top = 0
    Width = 960
    Height = 40
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object lblHeader: TLabel
      Transparent = True
      Left = 12
      Top = 11
      Width = 300
      Height = 15
      Caption = 'Ultimanium Audio Studio - system diagnostics'
    end
  end
  object pgc: TPageControl
    Left = 0
    Top = 40
    Width = 960
    Height = 561
    ActivePage = tabProject
    Align = alClient
    MultiLine = True
    TabOrder = 1
    OnChange = pgcChange
    object tabProject: TTabSheet
      Caption = 'Project'
      ImageIndex = 6
      PopupMenu = pmProject
      object pnlProjectTop: TPanel
        Left = 0
        Top = 0
        Width = 952
        Height = 168
        Align = alTop
        BevelOuter = bvNone
        TabOrder = 0
        object lblProjectFile: TLabel
          Transparent = True
          Left = 8
          Top = 8
          Width = 300
          Height = 15
          Caption = '(untitled - not saved)'
        end
        object lblProjectName: TLabel
          Transparent = True
          Left = 8
          Top = 34
          Width = 31
          Height = 15
          Caption = 'Name'
        end
        object lblProjectTempo: TLabel
          Transparent = True
          Left = 196
          Top = 34
          Width = 33
          Height = 15
          Caption = 'Tempo'
        end
        object lblProjectTimeSig: TLabel
          Transparent = True
          Left = 264
          Top = 34
          Width = 47
          Height = 15
          Caption = 'Time sig.'
        end
        object lblTimeSigSlash: TLabel
          Transparent = True
          Left = 298
          Top = 53
          Width = 8
          Height = 15
          Caption = '/'
        end
        object lblProjectSampleRate: TLabel
          Transparent = True
          Left = 348
          Top = 34
          Width = 60
          Height = 15
          Caption = 'Sample rate'
        end
        object lblProjectChannels: TLabel
          Transparent = True
          Left = 446
          Top = 34
          Width = 45
          Height = 15
          Caption = 'Channels'
        end
        object lblProjectAuthor: TLabel
          Transparent = True
          Left = 8
          Top = 76
          Width = 74
          Height = 15
          Caption = 'Author'#39's name'
        end
        object lblAutosave: TLabel
          Transparent = True
          Left = 8
          Top = 116
          Width = 44
          Height = 15
          Caption = 'Autosave'
        end
        object edtProjectName: TEdit
          Left = 8
          Top = 50
          Width = 180
          Height = 23
          TabOrder = 4
          OnExit = edtProjectNameExit
        end
        object edtProjectAuthor: TEdit
          Left = 8
          Top = 92
          Width = 180
          Height = 23
          TabOrder = 20
          OnExit = edtProjectAuthorExit
        end
        object edtProjectTempo: TEdit
          Left = 196
          Top = 50
          Width = 60
          Height = 23
          TabOrder = 5
        end
        object edtTimeSigNum: TEdit
          Left = 264
          Top = 50
          Width = 32
          Height = 23
          TabOrder = 6
        end
        object edtTimeSigDen: TEdit
          Left = 308
          Top = 50
          Width = 32
          Height = 23
          TabOrder = 7
        end
        object cboProjectSampleRate: TComboBox
          Left = 348
          Top = 50
          Width = 90
          Height = 23
          Style = csDropDownList
          TabOrder = 8
        end
        object edtProjectChannels: TEdit
          Left = 446
          Top = 50
          Width = 40
          Height = 23
          TabOrder = 9
        end
        object cboAutosaveInterval: TComboBox
          Left = 8
          Top = 132
          Width = 140
          Height = 23
          Style = csDropDownList
          TabOrder = 10
          OnChange = cboAutosaveIntervalChange
        end
      end
      object pnlProjectReadout: TPanel
        Left = 0
        Top = 168
        Width = 952
        Height = 361
        Align = alClient
        BevelOuter = bvNone
        TabOrder = 1
        object memProject: TMemo
          Left = 0
          Top = 0
          Width = 952
          Height = 361
          Align = alClient
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -12
          Font.Name = 'Consolas'
          Font.Style = []
          ParentFont = False
          ReadOnly = True
          ScrollBars = ssBoth
          TabOrder = 0
          WordWrap = False
        end
      end
    end
    object tabMixer: TTabSheet
      Caption = 'Mixer'
      ImageIndex = 11
      DoubleBuffered = True
      ParentDoubleBuffered = False
      object pnlMixTop: TPanel
        Left = 0
        Top = 0
        Width = 952
        Height = 172
        Align = alTop
        BevelOuter = bvNone
        TabOrder = 0
        object lblMixStrip: TLabel
          Transparent = True
          Left = 8
          Top = 12
          Width = 27
          Height = 15
          Caption = 'Strip'
        end
        object lblMixFader: TLabel
          Transparent = True
          Left = 8
          Top = 46
          Width = 47
          Height = 15
          Caption = 'Fader dB'
        end
        object lblMixPan: TLabel
          Transparent = True
          Left = 128
          Top = 46
          Width = 20
          Height = 15
          Caption = 'Pan'
        end
        object lblMixRoute: TLabel
          Transparent = True
          Left = 488
          Top = 12
          Width = 46
          Height = 15
          Caption = 'Route to'
        end
        object cboMixStrip: TComboBox
          Left = 44
          Top = 8
          Width = 180
          Height = 23
          Style = csDropDownList
          TabOrder = 0
          OnChange = cboMixStripChange
        end
        object lblMixTrackLink: TLabel
          Transparent = True
          Left = 236
          Top = 12
          Width = 49
          Height = 15
          Caption = 'Link track'
        end
        object cboMixTrackLink: TComboBox
          Left = 296
          Top = 8
          Width = 180
          Height = 23
          Style = csDropDownList
          TabOrder = 21
          OnChange = cboMixTrackLinkChange
        end
        object edtMixFader: TEdit
          Left = 64
          Top = 42
          Width = 52
          Height = 23
          TabOrder = 6
          Text = '0'
        end
        object edtMixPan: TEdit
          Left = 156
          Top = 42
          Width = 52
          Height = 23
          TabOrder = 7
          Text = '0'
        end
        object chkMixMute: TCheckBox
          Left = 224
          Top = 44
          Width = 52
          Height = 17
          Caption = 'Mute'
          TabOrder = 8
          OnClick = chkMixMuteClick
        end
        object chkMixSolo: TCheckBox
          Left = 284
          Top = 44
          Width = 52
          Height = 17
          Caption = 'Solo'
          TabOrder = 9
          OnClick = chkMixSoloClick
        end
        object cboMixRoute: TComboBox
          Left = 540
          Top = 8
          Width = 160
          Height = 23
          Style = csDropDownList
          TabOrder = 10
        end
        object cboMixInsertKind: TComboBox
          Left = 8
          Top = 76
          Width = 170
          Height = 23
          Style = csDropDownList
          TabOrder = 12
        end
        object btnMixAddVST: TButton
          Left = 596
          Top = 75
          Width = 110
          Height = 25
          Caption = 'Add VST...'
          TabOrder = 13
          OnClick = btnMixAddVSTClick
        end
        object btnMixEditVST: TButton
          Left = 712
          Top = 75
          Width = 110
          Height = 25
          Caption = 'Edit VST...'
          TabOrder = 14
          OnClick = btnMixEditVSTClick
        end
        object lblMixAutoParam: TLabel
          Transparent = True
          Left = 352
          Top = 46
          Width = 30
          Height = 15
          Caption = 'Auto'
        end
        object cboMixAutoParam: TComboBox
          Left = 386
          Top = 42
          Width = 190
          Height = 23
          Style = csDropDownList
          TabOrder = 15
          OnChange = cboMixAutoParamChange
        end
        object cboMixAutoMode: TComboBox
          Left = 584
          Top = 42
          Width = 100
          Height = 23
          Style = csDropDownList
          TabOrder = 16
          OnChange = cboMixAutoModeChange
        end
        object lblMixZoom: TLabel
          Transparent = True
          Left = 8
          Top = 112
          Width = 60
          Height = 15
          Caption = 'Strip width'
        end
        object tbMixZoom: TTrackBar
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
        object lblMixMasterLoudness: TLabel
          Transparent = True
          Left = 724
          Top = 8
          Width = 220
          Height = 40
          Caption = 'Master:  -inf dBFS   M -inf LUFS   I -inf LUFS'
          WordWrap = True
        end
        object lblMixMeterHold: TLabel
          Transparent = True
          Left = 240
          Top = 112
          Width = 44
          Height = 15
          Caption = 'Hold ms'
        end
        object lblMixMeterDecay: TLabel
          Transparent = True
          Left = 356
          Top = 112
          Width = 52
          Height = 15
          Caption = 'Decay dB/s'
        end
        object edtMixMeterHold: TEdit
          Left = 292
          Top = 108
          Width = 48
          Height = 23
          TabOrder = 18
          Text = '1500'
        end
        object edtMixMeterDecay: TEdit
          Left = 424
          Top = 108
          Width = 48
          Height = 23
          TabOrder = 19
          Text = '10'
        end
        object btnMixMeterApply: TButton
          Left = 480
          Top = 107
          Width = 48
          Height = 25
          Caption = 'Set'
          TabOrder = 20
          OnClick = btnMixMeterApplyClick
        end
        object btnMixAddInsertRow: TButton
          Left = 186
          Top = 75
          Width = 90
          Height = 25
          Caption = 'Add insert'
          TabOrder = 22
          OnClick = btnMixAddEQClick
        end
        object btnMixDelInsertRow: TButton
          Left = 282
          Top = 75
          Width = 100
          Height = 25
          Caption = 'Remove insert'
          TabOrder = 23
          OnClick = btnMixDelInsertClick
        end
        object btnMixApplyRow: TButton
          Left = 388
          Top = 75
          Width = 64
          Height = 25
          Caption = 'Apply'
          TabOrder = 24
          OnClick = btnMixApplyClick
        end
        object btnMixUndoRow: TButton
          Left = 458
          Top = 75
          Width = 56
          Height = 25
          Caption = 'Undo'
          TabOrder = 25
          OnClick = btnMixUndoClick
        end
        object btnMixRedoRow: TButton
          Left = 520
          Top = 75
          Width = 56
          Height = 25
          Caption = 'Redo'
          TabOrder = 26
          OnClick = btnMixRedoClick
        end
        object pbMixAuto: TPaintBox
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
      object pnlMixReadout: TPanel
        Left = 0
        Top = 371
        Width = 952
        Height = 160
        Align = alBottom
        BevelOuter = bvNone
        TabOrder = 1
        object memMix: TMemo
          Left = 0
          Top = 0
          Width = 952
          Height = 160
          Align = alClient
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -12
          Font.Name = 'Consolas'
          Font.Style = []
          ParentFont = False
          ReadOnly = True
          ScrollBars = ssBoth
          TabOrder = 0
          WordWrap = False
        end
      end
      object pbMixer: TPaintBox
        Left = 0
        Top = 140
        Width = 952
        Height = 231
        Align = alClient
        PopupMenu = pmMixer
        OnDblClick = pbMixerDblClick
        OnDragDrop = pbMixerDragDrop
        OnDragOver = pbMixerDragOver
        OnMouseDown = pbMixerMouseDown
        OnMouseMove = pbMixerMouseMove
        OnMouseUp = pbMixerMouseUp
        OnPaint = pbMixerPaint
      end
    end
    object tabRecording: TTabSheet
      Caption = 'Recording'
      ImageIndex = 9
      object pnlRecTop: TPanel
        Left = 0
        Top = 0
        Width = 952
        Height = 246
        Align = alTop
        BevelOuter = bvNone
        TabOrder = 0
        object lblRecChannels: TLabel
          Visible = False
          Transparent = True
          Left = 8
          Top = 10
          Width = 46
          Height = 15
          Caption = 'Channels'
        end
        object lblRecFormat: TLabel
          Transparent = True
          Left = 8
          Top = 10
          Width = 66
          Height = 15
          Caption = 'Take format'
        end
        object lblRecDuration: TLabel
          Visible = False
          Transparent = True
          Left = 360
          Top = 10
          Width = 96
          Height = 15
          Caption = 'Sim input len (s)'
        end
        object lblRecPreRoll: TLabel
          Transparent = True
          Left = 8
          Top = 44
          Width = 66
          Height = 15
          Caption = 'Pre-roll (s)'
        end
        object lblRecCountIn: TLabel
          Transparent = True
          Left = 130
          Top = 44
          Width = 96
          Height = 15
          Caption = 'Count-in (beats)'
        end
        object lblRecPunch: TLabel
          Transparent = True
          Left = 8
          Top = 78
          Width = 33
          Height = 15
          Caption = 'Punch'
        end
        object lblRecPunchIn: TLabel
          Transparent = True
          Left = 170
          Top = 78
          Width = 12
          Height = 15
          Caption = 'in'
        end
        object lblRecPunchOut: TLabel
          Transparent = True
          Left = 280
          Top = 78
          Width = 20
          Height = 15
          Caption = 'out'
        end
        object lblRecLoopStart: TLabel
          Transparent = True
          Left = 490
          Top = 78
          Width = 51
          Height = 15
          Caption = 'loop start'
        end
        object lblRecLoopEnd: TLabel
          Transparent = True
          Left = 600
          Top = 78
          Width = 45
          Height = 15
          Caption = 'loop end'
        end
        object cboRecChannels: TComboBox
          Visible = False
          Left = 60
          Top = 6
          Width = 100
          Height = 23
          Style = csDropDownList
          TabOrder = 0
        end
        object cboRecFormat: TComboBox
          Left = 80
          Top = 6
          Width = 110
          Height = 23
          Style = csDropDownList
          TabOrder = 1
        end
        object edtRecDuration: TEdit
          Visible = False
          Left = 460
          Top = 6
          Width = 24
          Height = 23
          TabOrder = 2
          Text = '4'
        end
        object edtRecPreRoll: TEdit
          Left = 80
          Top = 40
          Width = 36
          Height = 23
          TabOrder = 3
          Text = '0'
        end
        object edtRecCountIn: TEdit
          Left = 230
          Top = 40
          Width = 36
          Height = 23
          TabOrder = 4
          Text = '0'
        end
        object cboRecPunch: TComboBox
          Left = 60
          Top = 74
          Width = 100
          Height = 23
          Style = csDropDownList
          TabOrder = 5
          OnChange = cboRecPunchChange
        end
        object edtRecPunchIn: TEdit
          Left = 190
          Top = 74
          Width = 44
          Height = 23
          TabOrder = 6
          Text = '1.0'
        end
        object edtRecPunchOut: TEdit
          Left = 306
          Top = 74
          Width = 44
          Height = 23
          TabOrder = 7
          Text = '3.0'
        end
        object chkRecLoop: TCheckBox
          Left = 372
          Top = 76
          Width = 110
          Height = 17
          Caption = 'Loop-record'
          TabOrder = 8
          OnClick = chkRecLoopClick
        end
        object edtRecLoopStart: TEdit
          Left = 548
          Top = 74
          Width = 44
          Height = 23
          TabOrder = 9
          Text = '0'
        end
        object edtRecLoopEnd: TEdit
          Left = 650
          Top = 74
          Width = 44
          Height = 23
          TabOrder = 10
          Text = '2'
        end
        object chkRecMonitor: TCheckBox
          Left = 8
          Top = 112
          Width = 150
          Height = 17
          Caption = 'Input monitoring'
          TabOrder = 11
        end
        object btnRecArm: TButton
          Left = 8
          Top = 142
          Width = 190
          Height = 28
          Caption = 'Start live recording'
          TabOrder = 12
          OnClick = btnRecArmClick
        end
        object btnRecCommit: TButton
          Left = 208
          Top = 142
          Width = 150
          Height = 28
          Caption = 'Retry adding take'
          TabOrder = 13
          OnClick = btnRecCommitClick
        end
        object btnRecSaved: TButton
          Left = 408
          Top = 142
          Width = 150
          Height = 28
          Caption = 'Add saved audio...'
          TabOrder = 14
          OnClick = btnRecSavedClick
        end
        object btnRecScan: TButton
          Left = 608
          Top = 142
          Width = 190
          Height = 28
          Caption = 'Recover unfinished takes'
          TabOrder = 15
          OnClick = btnRecScanClick
        end
        object btnRecSaveTake: TButton
          Left = 8
          Top = 176
          Width = 190
          Height = 28
          Caption = 'Save Selected Take As...'
          TabOrder = 16
          OnClick = btnRecSaveTakeClick
        end
        object btnRecAddTakeToTimeline: TButton
          Left = 208
          Top = 176
          Width = 190
          Height = 28
          Caption = 'Add Selected Take to Timeline'
          TabOrder = 17
          OnClick = btnRecAddTakeToTimelineClick
        end
        object btnRecCommitComp: TButton
          Left = 404
          Top = 176
          Width = 190
          Height = 28
          Caption = 'Commit Comp to Timeline'
          TabOrder = 18
          OnClick = btnRecCommitCompClick
        end
        object btnRecResetComp: TButton
          Left = 600
          Top = 176
          Width = 110
          Height = 28
          Caption = 'Reset Comp'
          TabOrder = 19
          OnClick = btnRecResetCompClick
        end
        object lblRecMicState: TLabel
          Left = 370
          Top = 10
          Width = 410
          Height = 18
          Caption = 'Microphone: OFF | Recording: OFF'
          ShowHint = True
        end
        object lblRecDestination: TLabel
          Left = 8
          Top = 212
          Width = 780
          Height = 18
          Caption = 'Full input until Stop. Select input device and enable capture in Settings.'
        end
      end
      object pnlRecReadout: TPanel
        Left = 0
        Top = 371
        Width = 952
        Height = 160
        Align = alBottom
        BevelOuter = bvNone
        TabOrder = 1
        object memRec: TMemo
          Left = 0
          Top = 0
          Width = 952
          Height = 160
          Align = alClient
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -12
          Font.Name = 'Consolas'
          Font.Style = []
          ParentFont = False
          ReadOnly = True
          ScrollBars = ssBoth
          TabOrder = 0
          WordWrap = False
        end
      end
      object pbRecTakes: TPaintBox
        Left = 0
        Top = 164
        Width = 952
        Height = 207
        Align = alClient
        PopupMenu = pmRecording
        OnMouseDown = pbRecTakesMouseDown
        OnMouseMove = pbRecTakesMouseMove
        OnMouseUp = pbRecTakesMouseUp
        OnPaint = pbRecTakesPaint
      end
    end
    object tabTimeline: TTabSheet
      Caption = 'Timeline'
      ImageIndex = 8
      object pnlTimelineTop: TPanel
        Left = 0
        Top = 0
        Width = 952
        Height = 72
        Align = alTop
        BevelOuter = bvNone
        BevelKind = bkFlat
        BevelEdges = [beBottom]
        TabOrder = 0
        object lblTlSnap: TLabel
          Transparent = True
          Left = 12
          Top = 8
          Width = 30
          Height = 13
          Caption = 'SNAP'
          Font.Height = -11
          Font.Style = [fsBold]
          ParentFont = False
        end
        object bvlTlSep1: TBevel
          Left = 194
          Top = 8
          Width = 2
          Height = 56
          Shape = bsLeftLine
        end
        object lblTlTempo: TLabel
          Transparent = True
          Left = 210
          Top = 8
          Width = 76
          Height = 13
          Caption = 'TEMPO (BPM)'
          Font.Height = -11
          Font.Style = [fsBold]
          ParentFont = False
        end
        object bvlTlSep2: TBevel
          Left = 292
          Top = 8
          Width = 2
          Height = 56
          Shape = bsLeftLine
        end
        object lblTlPosCaption: TLabel
          Transparent = True
          Left = 308
          Top = 8
          Width = 46
          Height = 13
          Caption = 'POSITION'
          Font.Height = -11
          Font.Style = [fsBold]
          ParentFont = False
        end
        object lblTlPos: TLabel
          Transparent = True
          Left = 308
          Top = 26
          Width = 340
          Height = 19
          Caption = 'Playhead  1.1.000   00:00.000'
          Font.Height = -13
          Font.Name = 'Consolas'
          ParentFont = False
        end
        object bvlTlSep3: TBevel
          Left = 660
          Top = 8
          Width = 2
          Height = 56
          Shape = bsLeftLine
        end
        object lblTlMasterCaption: TLabel
          Transparent = True
          Left = 676
          Top = 8
          Width = 46
          Height = 13
          Caption = 'MASTER'
          Font.Height = -11
          Font.Style = [fsBold]
          ParentFont = False
        end
        object lblTlMasterVol: TLabel
          Transparent = True
          Left = 676
          Top = 26
          Width = 110
          Height = 15
          Caption = 'Master Vol  0.0 dB'
        end
        object edtTlTempo: TEdit
          Left = 210
          Top = 26
          Width = 70
          Height = 23
          TabOrder = 2
          Text = '120'
          OnExit = edtTlTempoExit
        end
        object chkTlMetronome: TCheckBox
          Left = 308
          Top = 48
          Width = 110
          Height = 17
          Caption = 'Metronome'
          TabOrder = 90
          OnClick = chkTlMetronomeClick
        end
        object cboTlSnap: TComboBox
          Left = 12
          Top = 26
          Width = 170
          Height = 23
          Style = csDropDownList
          TabOrder = 0
          OnChange = cboTlSnapChange
        end
        object tbTlMasterVol: TTrackBar
          Left = 674
          Top = 42
          Width = 170
          Height = 26
          Max = 12
          Min = -60
          Position = 0
          TabOrder = 1
          ThumbLength = 12
          OnChange = tbTlMasterVolChange
        end
        object pbTlMeters: TPaintBox
          Left = 852
          Top = 42
          Width = 96
          Height = 26
          OnPaint = pbTlMetersPaint
        end
      end
      object pnlTimelineReadout: TPanel
        Left = 0
        Top = 405
        Width = 952
        Height = 126
        Align = alBottom
        BevelOuter = bvNone
        TabOrder = 1
        object memTimeline: TMemo
          Left = 0
          Top = 0
          Width = 952
          Height = 126
          Align = alClient
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -12
          Font.Name = 'Consolas'
          Font.Style = []
          ParentFont = False
          ReadOnly = True
          ScrollBars = ssBoth
          TabOrder = 0
          WordWrap = False
        end
      end
      object sbTlHorz: TScrollBar
        Left = 0
        Top = 387
        Width = 952
        Height = 18
        Align = alBottom
        PageSize = 0
        TabOrder = 2
        OnChange = sbTlHorzChange
      end
      object sbTlVert: TScrollBar
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
      object pbTimeline: TWheelPaintBox
        Left = 0
        Top = 36
        Width = 952
        Height = 351
        Align = alClient
        OnDragDrop = pbTimelineDragDrop
        OnDragOver = pbTimelineDragOver
        OnMouseDown = pbTimelineMouseDown
        OnMouseMove = pbTimelineMouseMove
        OnMouseUp = pbTimelineMouseUp
        OnMouseWheel = pbTimelineMouseWheel
        OnPaint = pbTimelinePaint
      end
    end
    object tabTracker: TTabSheet
      Caption = 'Tracker'
      ImageIndex = 12
      DoubleBuffered = True
      ParentDoubleBuffered = False
      object pgcTrk: TPageControl
        Left = 0
        Top = 0
        Width = 952
        Height = 556
        ActivePage = tsTrkModule
        Align = alClient
        TabOrder = 0
      object tsTrkModule: TTabSheet
        Caption = 'Module'
      object pnlTrkTop: TPanel
        Left = 0
        Top = 0
        Width = 952
        Height = 80
        Align = alTop
        BevelOuter = bvNone
        TabOrder = 0
        object lblTrkPattern: TLabel
          Transparent = True
          Left = 8
          Top = 12
          Width = 41
          Height = 15
          Caption = 'Pattern'
        end
        object lblTrkSpeed: TLabel
          Transparent = True
          Left = 250
          Top = 12
          Width = 34
          Height = 15
          Caption = 'Speed'
        end
        object lblTrkBPM: TLabel
          Transparent = True
          Left = 330
          Top = 12
          Width = 27
          Height = 15
          Caption = 'BPM'
        end
        object lblTrkNote: TLabel
          Transparent = True
          Left = 8
          Top = 46
          Width = 27
          Height = 15
          Caption = 'Note'
        end
        object lblTrkInstr: TLabel
          Transparent = True
          Left = 110
          Top = 46
          Width = 17
          Height = 15
          Caption = 'Ins'
        end
        object lblTrkVol: TLabel
          Transparent = True
          Left = 178
          Top = 46
          Width = 20
          Height = 15
          Caption = 'Vol'
        end
        object lblTrkEff: TLabel
          Transparent = True
          Left = 246
          Top = 46
          Width = 13
          Height = 15
          Caption = 'Fx'
        end
        object lblTrkParam: TLabel
          Transparent = True
          Left = 304
          Top = 46
          Width = 22
          Height = 15
          Caption = 'Par'
        end
        object cboTrkPattern: TComboBox
          Left = 56
          Top = 8
          Width = 180
          Height = 23
          Style = csDropDownList
          TabOrder = 0
          OnChange = cboTrkPatternChange
        end
        object edtTrkSpeed: TEdit
          Left = 288
          Top = 8
          Width = 36
          Height = 23
          TabOrder = 1
          Text = '6'
        end
        object edtTrkBPM: TEdit
          Left = 362
          Top = 8
          Width = 40
          Height = 23
          TabOrder = 2
          Text = '125'
        end
        object edtTrkNote: TEdit
          Left = 42
          Top = 42
          Width = 56
          Height = 23
          TabOrder = 6
          Text = 'C-4'
        end
        object edtTrkInstr: TEdit
          Left = 132
          Top = 42
          Width = 36
          Height = 23
          TabOrder = 7
          Text = '1'
        end
        object edtTrkVol: TEdit
          Left = 202
          Top = 42
          Width = 36
          Height = 23
          TabOrder = 8
        end
        object edtTrkEff: TEdit
          Left = 264
          Top = 42
          Width = 28
          Height = 23
          MaxLength = 1
          TabOrder = 9
        end
        object edtTrkParam: TEdit
          Left = 330
          Top = 42
          Width = 36
          Height = 23
          MaxLength = 2
          TabOrder = 10
        end
      end
      object pnlTrkSupport: TPanel
        Left = 0
        Top = 500
        Width = 952
        Height = 56
        Align = alBottom
        BevelOuter = bvNone
        TabOrder = 3
        object lblTrkSupport: TLabel
          Left = 0
          Top = 0
          Width = 740
          Height = 56
          Align = alClient
          AutoSize = False
          Caption = 'For dedicated tracker-module editing, visit and support ModPlug and its tracker development. UDAW uses modules in your projects and provides focused editing tools.'
          Layout = tlCenter
          WordWrap = True
        end
        object btnTrkSupport: TButton
          Left = 740
          Top = 0
          Width = 212
          Height = 56
          Align = alRight
          Caption = 'Visit www.modplug.com'
          TabOrder = 0
          OnClick = btnTrkSupportClick
        end
      end
      object pnlTrkReadout: TPanel
        Left = 0
        Top = 381
        Width = 952
        Height = 150
        Align = alBottom
        BevelOuter = bvNone
        TabOrder = 1
        DoubleBuffered = True
        ParentDoubleBuffered = False
        object memTrk: TMemo
          Left = 0
          Top = 0
          Width = 952
          Height = 150
          Align = alClient
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -12
          Font.Name = 'Consolas'
          Font.Style = []
          ParentFont = False
          ReadOnly = True
          ScrollBars = ssBoth
          TabOrder = 0
          WordWrap = False
        end
      end
      object pnlTrkSequence: TPanel
        Left = 0
        Top = 80
        Width = 952
        Height = 58
        Align = alTop
        BevelOuter = bvNone
        TabOrder = 2
        DoubleBuffered = True
        ParentDoubleBuffered = False
        object lblTrkSeq: TLabel
          Transparent = True
          Left = 8
          Top = 2
          Width = 300
          Height = 15
          Caption = 'Sequence (click a step to jump / view its pattern)'
        end
        object pbTrkSequence: TPaintBox
          Left = 0
          Top = 18
          Width = 952
          Height = 24
          Align = alTop
          PopupMenu = pmTrkSeq
          OnMouseDown = pbTrkSequenceMouseDown
          OnPaint = pbTrkSequencePaint
        end
        object sbTrkSeq: TScrollBar
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
      object pbTracker: TWheelPaintBox
        Left = 0
        Top = 138
        Width = 952
        Height = 227
        Align = alClient
        PopupMenu = pmTrkGrid
        OnMouseDown = pbTrackerMouseDown
        OnMouseWheel = pbTrackerMouseWheel
        OnPaint = pbTrackerPaint
      end
      object sbTrkChn: TScrollBar
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
      object tsTrkInstruments: TTabSheet
        Caption = 'Instruments'
        object pnlTrkInstrTop: TPanel
          Left = 0
          Top = 0
          Width = 952
          Height = 44
          Align = alTop
          BevelOuter = bvNone
          TabOrder = 0
          object lblTrkInstrSel: TLabel
            Transparent = True
            Left = 8
            Top = 12
            Width = 56
            Height = 15
            Caption = 'Instrument'
          end
          object cboTrkInstrSel: TComboBox
            Left = 76
            Top = 8
            Width = 260
            Height = 23
            Style = csDropDownList
            TabOrder = 0
            OnChange = cboTrkInstrSelChange
          end
          object btnTrkInstrAddTimeline: TButton
            Left = 348
            Top = 7
            Width = 140
            Height = 25
            Caption = 'Add to Timeline'
            TabOrder = 1
            OnClick = btnTrkInstrAddTimelineClick
          end
          object btnTrkInstrSaveWav: TButton
            Left = 496
            Top = 7
            Width = 180
            Height = 25
            Caption = 'Export WAV/PCM/FLAC...'
            TabOrder = 2
            OnClick = btnTrkInstrSaveWavClick
          end
        end
        object pnlTrkInstrInfo: TPanel
          Left = 0
          Top = 44
          Width = 952
          Height = 24
          Align = alTop
          BevelOuter = bvNone
          TabOrder = 1
          object lblTrkInstrInfo: TLabel
            Transparent = True
            Left = 8
            Top = 4
            Width = 300
            Height = 15
            Caption = '(no instrument selected)'
          end
        end
        object pbTrkInstrWave: TWheelPaintBox
          Left = 0
          Top = 68
          Width = 952
          Height = 488
          Align = alClient
          OnPaint = pbTrkInstrWavePaint
        end
      end
      end
    end
    object tabMIDI: TTabSheet
      Caption = 'MIDI'
      ImageIndex = 15
      object pnlMidiTop: TPanel
        Left = 0
        Top = 0
        Width = 952
        Height = 116
        Align = alTop
        BevelOuter = bvNone
        TabOrder = 0
        object lblMidiClip: TLabel
          Transparent = True
          Left = 8
          Top = 14
          Width = 22
          Height = 15
          Caption = 'Clip'
        end
        object lblMidiNote: TLabel
          Transparent = True
          Left = 8
          Top = 48
          Width = 100
          Height = 15
          Caption = 'note  start  len  vel'
        end
        object lblMidiGrid: TLabel
          Transparent = True
          Left = 8
          Top = 84
          Width = 22
          Height = 15
          Caption = 'Grid'
        end
        object cboMidiClip: TComboBox
          Left = 40
          Top = 10
          Width = 180
          Height = 23
          Style = csDropDownList
          TabOrder = 0
          OnChange = cboMidiClipChange
        end
        object edtMidiNote: TEdit
          Left = 120
          Top = 44
          Width = 44
          Height = 23
          TabOrder = 3
          Text = '60'
        end
        object edtMidiStart: TEdit
          Left = 168
          Top = 44
          Width = 56
          Height = 23
          TabOrder = 4
          Text = '0'
        end
        object edtMidiLen: TEdit
          Left = 228
          Top = 44
          Width = 56
          Height = 23
          TabOrder = 5
          Text = '480'
        end
        object edtMidiVel: TEdit
          Left = 288
          Top = 44
          Width = 44
          Height = 23
          TabOrder = 6
          Text = '100'
        end
        object cboMidiGrid: TComboBox
          Left = 40
          Top = 80
          Width = 90
          Height = 23
          Style = csDropDownList
          TabOrder = 9
        end
        object lblMidiScale: TLabel
          Transparent = True
          Left = 420
          Top = 14
          Width = 33
          Height = 15
          Caption = 'Scale'
        end
        object cboMidiScaleRoot: TComboBox
          Left = 460
          Top = 10
          Width = 70
          Height = 23
          Style = csDropDownList
          TabOrder = 10
          OnChange = cboMidiScaleChange
        end
        object cboMidiScaleType: TComboBox
          Left = 536
          Top = 10
          Width = 140
          Height = 23
          Style = csDropDownList
          TabOrder = 11
          OnChange = cboMidiScaleChange
        end
        object chkMidiScaleHighlight: TCheckBox
          Left = 460
          Top = 44
          Width = 216
          Height = 17
          Caption = 'Highlight scale'
          TabOrder = 12
          OnClick = chkMidiScaleHighlightClick
        end
      end
      object pbPianoRoll: TPaintBox
        Left = 0
        Top = 116
        Width = 952
        Height = 250
        Align = alTop
        PopupMenu = pmPianoRoll
        OnMouseDown = pbPianoRollMouseDown
        OnMouseMove = pbPianoRollMouseMove
        OnMouseUp = pbPianoRollMouseUp
        OnPaint = pbPianoRollPaint
      end
      object memMidi: TMemo
        Left = 0
        Top = 366
        Width = 952
        Height = 165
        Align = alClient
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clWindowText
        Font.Height = -12
        Font.Name = 'Consolas'
        Font.Style = []
        ParentFont = False
        ReadOnly = True
        ScrollBars = ssBoth
        TabOrder = 1
        WordWrap = False
      end
    end
    object tabSettings: TTabSheet
      Caption = 'Settings'
      ImageIndex = 16
      object pgcSettings: TPageControl
        Left = 0
        Top = 0
        Width = 952
        Height = 531
        Align = alClient
        ActivePage = tabSettingsGeneral
        TabOrder = 0
        OnChange = pgcChange
        object tabSettingsGeneral: TTabSheet
          Caption = 'General'
          PopupMenu = pmSettings
          object sbSettings: TScrollBox
            Left = 0
            Top = 0
            Width = 952
            Height = 531
            Align = alClient
            TabOrder = 0
            object grpStartup: TGroupBox
              Left = 8
              Top = 0
              Width = 920
              Height = 390
              Caption = ' Startup && Audio Engine '
              TabOrder = 0
              object lblSetBackend: TLabel
                Transparent = True
                Left = 16
                Top = 27
                Width = 140
                Height = 15
                Caption = 'Audio backend'
              end
              object lblSettingsStatus: TLabel
                Transparent = True
                Left = 800
                Top = 27
                Width = 3
                Height = 15
                Anchors = [akTop, akRight]
                Caption = ' '
              end
              object cboSetBackend: TComboBox
                Left = 164
                Top = 24
                Width = 140
                Height = 23
                Style = csDropDownList
                TabOrder = 0
              end
              object lblSetRate: TLabel
                Transparent = True
                Left = 16
                Top = 59
                Width = 140
                Height = 15
                Caption = 'Sample rate (Hz)'
              end
              object cboSetRate: TComboBox
                Left = 164
                Top = 56
                Width = 110
                Height = 23
                Style = csDropDownList
                TabOrder = 1
              end
              object lblSetBuffer: TLabel
                Transparent = True
                Left = 16
                Top = 91
                Width = 140
                Height = 15
                Caption = 'Buffer size (frames)'
              end
              object cboSetBuffer: TComboBox
                Left = 164
                Top = 88
                Width = 110
                Height = 23
                Style = csDropDownList
                TabOrder = 2
              end
              object lblSetOutCh: TLabel
                Transparent = True
                Left = 16
                Top = 123
                Width = 140
                Height = 15
                Caption = 'Output channels'
              end
              object edSetOutCh: TEdit
                Left = 164
                Top = 120
                Width = 60
                Height = 23
                NumbersOnly = True
                TabOrder = 3
                Text = '2'
              end
              object lblSetInCh: TLabel
                Transparent = True
                Left = 16
                Top = 155
                Width = 140
                Height = 15
                Caption = 'Input channels'
              end
              object edSetInCh: TEdit
                Left = 164
                Top = 152
                Width = 60
                Height = 23
                NumbersOnly = True
                TabOrder = 4
                Text = '2'
              end
              object lblSetInDevice: TLabel
                Transparent = True
                Left = 240
                Top = 155
                Width = 90
                Height = 15
                Caption = 'Input device'
              end
              object cboSetInDevice: TComboBox
                Left = 336
                Top = 152
                Width = 260
                Height = 23
                Style = csDropDownList
                TabOrder = 11
              end
              object chkSetAutostart: TCheckBox
                Left = 16
                Top = 184
                Width = 400
                Height = 17
                Caption = 'Auto-start audio engine on launch'
                TabOrder = 5
              end
              object chkSetCapture: TCheckBox
                Left = 16
                Top = 216
                Width = 400
                Height = 17
                Caption = 'Enable audio input (capture)'
                TabOrder = 6
              end
              object chkSetExclusive: TCheckBox
                Left = 16
                Top = 248
                Width = 400
                Height = 17
                Caption = 'Exclusive-mode output (WASAPI)'
                TabOrder = 7
              end
              object lblSetLogLevel: TLabel
                Transparent = True
                Left = 16
                Top = 283
                Width = 140
                Height = 15
                Caption = 'Log level'
              end
              object cboSetLogLevel: TComboBox
                Left = 164
                Top = 280
                Width = 110
                Height = 23
                Style = csDropDownList
                TabOrder = 8
              end
              object lblSetLocale: TLabel
                Transparent = True
                Left = 300
                Top = 283
                Width = 60
                Height = 15
                Caption = 'Locale'
              end
              object edSetLocale: TEdit
                Left = 366
                Top = 280
                Width = 80
                Height = 23
                TabOrder = 9
                Text = 'en'
              end
              object chkSetTempoAuto: TCheckBox
                Left = 16
                Top = 308
                Width = 430
                Height = 17
                Caption = 'Auto-detect BPM from the first imported audio track (sets Timeline BPM)'
                Checked = True
                State = cbChecked
                TabOrder = 11
              end
              object chkSetTempoResample: TCheckBox
                Left = 16
                Top = 325
                Width = 430
                Height = 17
                Caption = 'Conform clip tempo by resampling (pitch follows tempo)'
                TabOrder = 12
              end
              object chkSetHints: TCheckBox
                Left = 470
                Top = 325
                Width = 430
                Height = 17
                Hint = 'Show a hint bubble when the mouse rests over a control. Applies to the whole application and every project.'
                Caption = 'Show hints when hovering over controls'
                Checked = True
                ParentShowHint = False
                ShowHint = True
                State = cbChecked
                TabOrder = 13
              end
              object lblSetTheme: TLabel
                Transparent = True
                Left = 16
                Top = 347
                Width = 140
                Height = 15
                Caption = 'Visual theme'
              end
              object cboSetTheme: TComboBox
                Left = 164
                Top = 344
                Width = 220
                Height = 23
                Style = csDropDownList
                TabOrder = 10
                OnChange = cboSetThemeChange
              end
              object lblThemeInfo: TLabel
                Transparent = True
                Left = 400
                Top = 347
                Width = 3
                Height = 15
                Caption = ' '
              end
            end
            object grpDirs: TGroupBox
              Left = 8
              Top = 398
              Width = 920
              Height = 262
              Caption = ' Working Directories '
              TabOrder = 1
              object lblDirProjects: TLabel
                Transparent = True
                Left = 16
                Top = 27
                Width = 150
                Height = 15
                Caption = 'Projects'
              end
              object edDirProjects: TEdit
                Left = 170
                Top = 24
                Width = 650
                Height = 23
                TabOrder = 0
              end
              object btnDirProjects: TButton
                Left = 828
                Top = 23
                Width = 80
                Height = 25
                Caption = 'Browse...'
                TabOrder = 1
                Tag = 1
                OnClick = btnSettingsBrowseDirClick
              end
              object lblDirAudioLib: TLabel
                Transparent = True
                Left = 16
                Top = 59
                Width = 150
                Height = 15
                Caption = 'Audio / media library'
              end
              object edDirAudioLib: TEdit
                Left = 170
                Top = 56
                Width = 650
                Height = 23
                TabOrder = 2
              end
              object btnDirAudioLib: TButton
                Left = 828
                Top = 55
                Width = 80
                Height = 25
                Caption = 'Browse...'
                TabOrder = 3
                Tag = 2
                OnClick = btnSettingsBrowseDirClick
              end
              object lblDirSfx: TLabel
                Transparent = True
                Left = 16
                Top = 91
                Width = 150
                Height = 15
                Caption = 'Sound effects (SFX)'
              end
              object edDirSfx: TEdit
                Left = 170
                Top = 88
                Width = 650
                Height = 23
                TabOrder = 4
              end
              object btnDirSfx: TButton
                Left = 828
                Top = 87
                Width = 80
                Height = 25
                Caption = 'Browse...'
                TabOrder = 5
                Tag = 3
                OnClick = btnSettingsBrowseDirClick
              end
              object lblDirExport: TLabel
                Transparent = True
                Left = 16
                Top = 123
                Width = 150
                Height = 15
                Caption = 'Export / render output'
              end
              object edDirExport: TEdit
                Left = 170
                Top = 120
                Width = 650
                Height = 23
                TabOrder = 6
              end
              object btnDirExport: TButton
                Left = 828
                Top = 119
                Width = 80
                Height = 25
                Caption = 'Browse...'
                TabOrder = 7
                Tag = 4
                OnClick = btnSettingsBrowseDirClick
              end
              object lblDirRecordings: TLabel
                Transparent = True
                Left = 16
                Top = 155
                Width = 150
                Height = 15
                Caption = 'Recordings'
              end
              object edDirRecordings: TEdit
                Left = 170
                Top = 152
                Width = 650
                Height = 23
                TabOrder = 8
              end
              object btnDirRecordings: TButton
                Left = 828
                Top = 151
                Width = 80
                Height = 25
                Caption = 'Browse...'
                TabOrder = 9
                Tag = 5
                OnClick = btnSettingsBrowseDirClick
              end
              object lblDirTemp: TLabel
                Transparent = True
                Left = 16
                Top = 193
                Width = 150
                Height = 15
                Caption = 'Temporary files'
              end
              object edDirTemp: TEdit
                Left = 170
                Top = 190
                Width = 650
                Height = 23
                TabOrder = 10
              end
              object btnDirTemp: TButton
                Left = 828
                Top = 189
                Width = 80
                Height = 25
                Caption = 'Browse...'
                TabOrder = 11
                Tag = 6
                OnClick = btnSettingsBrowseDirClick
              end
              object lblDirCache: TLabel
                Transparent = True
                Left = 16
                Top = 225
                Width = 150
                Height = 15
                Caption = 'Cache files'
              end
              object edDirCache: TEdit
                Left = 170
                Top = 222
                Width = 650
                Height = 23
                TabOrder = 12
              end
              object btnDirCache: TButton
                Left = 828
                Top = 221
                Width = 80
                Height = 25
                Caption = 'Browse...'
                TabOrder = 13
                Tag = 7
                OnClick = btnSettingsBrowseDirClick
              end
            end
            object grpSystemPaths: TGroupBox
              Left = 8
              Top = 668
              Width = 920
              Height = 170
              Caption = ' System Locations (read-only) '
              TabOrder = 2
              object memSysPaths: TMemo
                Left = 16
                Top = 24
                Width = 888
                Height = 130
                Font.Charset = DEFAULT_CHARSET
                Font.Color = clWindowText
                Font.Height = -12
                Font.Name = 'Consolas'
                Font.Style = []
                ParentFont = False
                ReadOnly = True
                ScrollBars = ssVertical
                TabOrder = 0
                WordWrap = False
              end
            end
            object grpColorTheme: TGroupBox
              Left = 8
              Top = 846
              Width = 920
              Height = 90
              Caption = ' Color Theme'
              TabOrder = 3
              object lblColorTheme: TLabel
                Transparent = True
                Left = 16
                Top = 27
                Width = 140
                Height = 15
                Caption = 'Theme'
              end
              object cboColorTheme: TComboBox
                Left = 164
                Top = 24
                Width = 220
                Height = 23
                Style = csDropDownList
                TabOrder = 0
                OnChange = cboColorThemeChange
              end
              object btnColorThemeSave: TButton
                Left = 16
                Top = 56
                Width = 100
                Height = 25
                Caption = 'Save copy...'
                TabOrder = 1
                OnClick = btnColorThemeSaveClick
              end
              object btnColorThemeReset: TButton
                Left = 122
                Top = 56
                Width = 80
                Height = 25
                Caption = 'Reset'
                TabOrder = 2
                OnClick = btnColorThemeResetClick
              end
              object btnColorThemeExport: TButton
                Left = 208
                Top = 56
                Width = 80
                Height = 25
                Caption = 'Export...'
                TabOrder = 3
                OnClick = btnColorThemeExportClick
              end
              object btnColorThemeImport: TButton
                Left = 294
                Top = 56
                Width = 80
                Height = 25
                Caption = 'Import...'
                TabOrder = 4
                OnClick = btnColorThemeImportClick
              end
              object lblColorThemeStatus: TLabel
                Transparent = True
                Left = 400
                Top = 62
                Width = 3
                Height = 15
                Caption = ' '
              end
            end
            object grpMidiDevices: TGroupBox
              Left = 8
              Top = 944
              Width = 920
              Height = 110
              Caption = ' MIDI Devices'
              TabOrder = 4
              object lblSetMidiIn: TLabel
                Transparent = True
                Left = 16
                Top = 27
                Width = 150
                Height = 15
                Caption = 'Input device'
              end
              object lblSetMidiOut: TLabel
                Transparent = True
                Left = 16
                Top = 66
                Width = 150
                Height = 15
                Caption = 'Output device'
              end
              object cboSetMidiInDevice: TComboBox
                Left = 164
                Top = 24
                Width = 340
                Height = 23
                Style = csDropDownList
                TabOrder = 0
                OnChange = cboSetMidiInDeviceChange
              end
              object cboSetMidiOutDevice: TComboBox
                Left = 164
                Top = 63
                Width = 340
                Height = 23
                Style = csDropDownList
                TabOrder = 1
                OnChange = cboSetMidiOutDeviceChange
              end
              object btnSetMidiRefresh: TButton
                Left = 520
                Top = 24
                Width = 100
                Height = 25
                Caption = 'Refresh list'
                TabOrder = 2
                OnClick = btnSetMidiRefreshClick
              end
              object btnSetMidiPanic: TButton
                Left = 520
                Top = 63
                Width = 100
                Height = 25
                Caption = 'MIDI Panic'
                TabOrder = 3
                OnClick = btnSetMidiPanicClick
              end
              object lblSetMidiStatus: TLabel
                Transparent = True
                Left = 640
                Top = 68
                Width = 3
                Height = 15
                Caption = ' '
              end
            end
          end
        end
        object tabRegistration: TTabSheet
          Caption = 'Registration'
          object grpRegStatus: TGroupBox
            Left = 8
            Top = 8
            Width = 920
            Height = 88
            Caption = ' Registration status '
            TabOrder = 0
            object lblRegStatus: TLabel
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
            object lblRegDetail: TLabel
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
          object grpRegCredentials: TGroupBox
            Left = 8
            Top = 104
            Width = 920
            Height = 216
            Caption = ' Account credentials (from ultimanium.com) '
            TabOrder = 1
            object lblRegUsername: TLabel
              Left = 16
              Top = 30
              Width = 100
              Height = 15
              Caption = 'Username'
              Transparent = True
            end
            object edtRegUsername: TEdit
              Left = 164
              Top = 27
              Width = 300
              Height = 23
              TabOrder = 0
            end
            object lblRegPassword: TLabel
              Left = 16
              Top = 62
              Width = 100
              Height = 15
              Caption = 'Password'
              Transparent = True
            end
            object edtRegPassword: TEdit
              Left = 164
              Top = 59
              Width = 300
              Height = 23
              PasswordChar = '*'
              TabOrder = 1
            end
            object lblRegSerial: TLabel
              Left = 16
              Top = 94
              Width = 100
              Height = 15
              Caption = 'Serial number key'
              Transparent = True
            end
            object edtRegSerial: TEdit
              Left = 164
              Top = 91
              Width = 300
              Height = 23
              TabOrder = 2
            end
            object btnRegRegister: TButton
              Left = 164
              Top = 128
              Width = 120
              Height = 27
              Caption = 'Register'
              Default = True
              TabOrder = 3
              OnClick = btnRegRegisterClick
            end
            object btnRegUnregister: TButton
              Left = 292
              Top = 128
              Width = 120
              Height = 27
              Caption = 'Unregister'
              TabOrder = 4
              OnClick = btnRegUnregisterClick
            end
            object lblRegHint: TLabel
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
          object grpRegUpdate: TGroupBox
            Left = 8
            Top = 328
            Width = 920
            Height = 120
            Caption = ' Updates '
            TabOrder = 2
            object lblRegVersion: TLabel
              Left = 16
              Top = 30
              Width = 888
              Height = 15
              Anchors = [akLeft, akTop, akRight]
              AutoSize = False
              Caption = 'Installed version:'
              Transparent = True
            end
            object lblRegUpdateStatus: TLabel
              Left = 16
              Top = 54
              Width = 888
              Height = 15
              Anchors = [akLeft, akTop, akRight]
              AutoSize = False
              Caption = ' '
              Transparent = True
            end
            object btnRegCheckUpdate: TButton
              Left = 16
              Top = 80
              Width = 150
              Height = 27
              Caption = 'Check for updates'
              TabOrder = 0
              OnClick = btnRegCheckUpdateClick
            end
            object btnRegInstallUpdate: TButton
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
        object tabColors: TTabSheet
          Caption = 'Colours'
          object pnlColorsTop: TPanel
            Left = 0
            Top = 0
            Width = 952
            Height = 40
            Align = alTop
            BevelOuter = bvNone
            TabOrder = 0
            object lblColorsTitle: TLabel
              Transparent = True
              Left = 8
              Top = 13
              Width = 400
              Height = 15
              Caption = 'Editing theme colors'
            end
          end
          object lbColorSwatches: TListBox
            Left = 8
            Top = 48
            Width = 280
            Height = 480
            ItemHeight = 15
            TabOrder = 1
            OnClick = lbColorSwatchesClick
          end
          object pbColorPreview: TPaintBox
            Left = 300
            Top = 48
            Width = 140
            Height = 40
            OnPaint = pbColorPreviewPaint
          end
          object btnColorPick: TButton
            Left = 300
            Top = 96
            Width = 140
            Height = 25
            Caption = 'Change Color...'
            TabOrder = 3
            OnClick = btnColorPickClick
          end
          object btnColorsSave: TButton
            Left = 300
            Top = 130
            Width = 140
            Height = 25
            Caption = 'Save to Theme'
            TabOrder = 4
            OnClick = btnColorsSaveClick
          end
          object btnColorsResetTheme: TButton
            Left = 300
            Top = 164
            Width = 140
            Height = 25
            Caption = 'Reset Theme Colors'
            TabOrder = 5
            OnClick = btnColorsResetThemeClick
          end
          object lblColorsStatus: TLabel
            Transparent = True
            Left = 300
            Top = 200
            Width = 3
            Height = 15
            Caption = ' '
          end
          object lblColorsHint: TLabel
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
          object lblFadeDisplay: TLabel
            Left = 300
            Top = 322
            Caption = 'Fade representation (all timeline clips)'
          end
          object cboFadeDisplay: TComboBox
            Left = 300
            Top = 344
            Width = 270
            Height = 23
            Style = csDropDownList
            TabOrder = 6
            ItemIndex = 0
            Items.Strings = (
              'Coloured areas'
              'Graphical curves and handles'
              'Coloured areas with curves')
            OnChange = cboFadeDisplayChange
          end
        end
        object tabKeyHooks: TTabSheet
          Caption = 'Key Hooks'
          object lblKeyHooksHint: TLabel
            Transparent = True
            Left = 8
            Top = 8
            Width = 920
            Height = 15
            Caption = 'All keyboard shortcuts currently assigned in UDAW. Select a global row and click Assign New Key to rebind it.'
          end
          object lvKeyHooks: TListView
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
                Width = 350
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
          object btnKeyHookAssign: TButton
            Left = 8
            Top = 458
            Width = 160
            Height = 25
            Caption = 'Assign New Key...'
            TabOrder = 1
            OnClick = btnKeyHookAssignClick
          end
          object btnKeyHookSave: TButton
            Left = 176
            Top = 458
            Width = 120
            Height = 25
            Caption = 'Save'
            TabOrder = 2
            OnClick = btnKeyHookSaveClick
          end
          object btnKeyHookRestore: TButton
            Left = 304
            Top = 458
            Width = 160
            Height = 25
            Caption = 'Restore Defaults'
            TabOrder = 3
            OnClick = btnKeyHookRestoreClick
          end
          object btnKeyHookToggle: TButton
            Left = 472
            Top = 458
            Width = 160
            Height = 25
            Caption = 'Enable / Disable'
            TabOrder = 4
            OnClick = btnKeyHookToggleClick
          end
        end
        object tabSettingsDiagnostics: TTabSheet
          Caption = 'Diagnostics'
          object pgcDiagnostics: TPageControl
            Left = 0
            Top = 0
            Width = 936
            Height = 475
            Align = alClient
            ActivePage = tabSystem
            TabOrder = 0
            OnChange = pgcChange
            object tabSystem: TTabSheet
              Caption = 'System'
              object memSystem: TMemo
                Left = 0
                Top = 0
                Width = 952
                Height = 531
                Align = alClient
                Font.Charset = DEFAULT_CHARSET
                Font.Color = clWindowText
                Font.Height = -12
                Font.Name = 'Consolas'
                Font.Style = []
                ParentFont = False
                PopupMenu = pmSystem
                ReadOnly = True
                ScrollBars = ssBoth
                TabOrder = 0
                WordWrap = False
              end
            end
            object tabJobs: TTabSheet
              Caption = 'Jobs'
              ImageIndex = 2
              object lvJobs: TListView
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
            object tabAudio: TTabSheet
              Caption = 'Audio'
              ImageIndex = 3
              object pnlAudioMeters: TPanel
                Left = 0
                Top = 0
                Width = 952
                Height = 64
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                object lblOutL: TLabel
                  Transparent = True
                  Left = 8
                  Top = 10
                  Width = 30
                  Height = 15
                  Caption = 'Out L'
                end
                object lblOutR: TLabel
                  Transparent = True
                  Left = 8
                  Top = 36
                  Width = 31
                  Height = 15
                  Caption = 'Out R'
                end
                object pbOutL: TProgressBar
                  Left = 48
                  Top = 8
                  Width = 500
                  Height = 18
                  Max = 1000
                  TabOrder = 0
                end
                object pbOutR: TProgressBar
                  Left = 48
                  Top = 34
                  Width = 500
                  Height = 18
                  Max = 1000
                  TabOrder = 1
                end
                object lblAudioState: TLabel
                  Transparent = True
                  Left = 564
                  Top = 10
                  Width = 3
                  Height = 15
                  Caption = ' '
                end
              end
              object memAudio: TMemo
                Left = 0
                Top = 64
                Width = 952
                Height = 467
                Align = alClient
                Font.Charset = DEFAULT_CHARSET
                Font.Color = clWindowText
                Font.Height = -12
                Font.Name = 'Consolas'
                Font.Style = []
                ParentFont = False
                PopupMenu = pmAudio
                ReadOnly = True
                ScrollBars = ssBoth
                TabOrder = 1
                WordWrap = False
              end
            end
            object tabDSP: TTabSheet
              Caption = 'DSP'
              ImageIndex = 4
              object pnlDspTop: TPanel
                Left = 0
                Top = 0
                Width = 952
                Height = 72
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                object lblDspSignal: TLabel
                  Transparent = True
                  Left = 8
                  Top = 6
                  Width = 32
                  Height = 15
                  Caption = 'Signal'
                end
                object lblDspFilter: TLabel
                  Transparent = True
                  Left = 200
                  Top = 6
                  Width = 26
                  Height = 15
                  Caption = 'Filter'
                end
                object lblDspWindow: TLabel
                  Transparent = True
                  Left = 452
                  Top = 6
                  Width = 62
                  Height = 15
                  Caption = 'FFT window'
                end
                object cboDspSignal: TComboBox
                  Left = 8
                  Top = 22
                  Width = 180
                  Height = 23
                  Style = csDropDownList
                  TabOrder = 0
                end
                object cboDspFilter: TComboBox
                  Left = 200
                  Top = 22
                  Width = 240
                  Height = 23
                  Style = csDropDownList
                  TabOrder = 1
                end
                object cboDspWindow: TComboBox
                  Left = 452
                  Top = 22
                  Width = 150
                  Height = 23
                  Style = csDropDownList
                  TabOrder = 2
                end
                object chkDspLive: TCheckBox
                  Left = 736
                  Top = 24
                  Width = 90
                  Height = 17
                  Caption = 'Live'
                  TabOrder = 4
                  OnClick = chkDspLiveClick
                end
              end
              object pnlDspReadout: TPanel
                Left = 0
                Top = 381
                Width = 952
                Height = 150
                Align = alBottom
                BevelOuter = bvNone
                TabOrder = 1
                object memDspReadout: TMemo
                  Left = 0
                  Top = 0
                  Width = 952
                  Height = 150
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
              object pbSpectrum: TPaintBox
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
            object tabGraph: TTabSheet
              Caption = 'Graph'
              ImageIndex = 5
              object pnlGraphTop: TPanel
                Left = 0
                Top = 0
                Width = 952
                Height = 72
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                object lblGraphPreset: TLabel
                  Transparent = True
                  Left = 8
                  Top = 6
                  Width = 34
                  Height = 15
                  Caption = 'Preset'
                end
                object cboGraphPreset: TComboBox
                  Left = 8
                  Top = 22
                  Width = 420
                  Height = 23
                  Style = csDropDownList
                  TabOrder = 0
                end
                object chkGraphLive: TCheckBox
                  Left = 712
                  Top = 24
                  Width = 90
                  Height = 17
                  Caption = 'Live'
                  TabOrder = 3
                  OnClick = chkGraphLiveClick
                end
              end
              object pnlGraphReadout: TPanel
                Left = 0
                Top = 361
                Width = 952
                Height = 170
                Align = alBottom
                BevelOuter = bvNone
                TabOrder = 1
                object memGraph: TMemo
                  Left = 0
                  Top = 0
                  Width = 952
                  Height = 170
                  Align = alClient
                  Font.Charset = DEFAULT_CHARSET
                  Font.Color = clWindowText
                  Font.Height = -12
                  Font.Name = 'Consolas'
                  Font.Style = []
                  ParentFont = False
                  ReadOnly = True
                  ScrollBars = ssBoth
                  TabOrder = 0
                  WordWrap = False
                end
              end
              object pbGraph: TPaintBox
                Left = 0
                Top = 72
                Width = 952
                Height = 289
                Align = alClient
                PopupMenu = pmGraph
                OnPaint = pbGraphPaint
              end
            end
            object tabWav: TTabSheet
              Caption = 'Supported SFX'
              ImageIndex = 7
              object pnlWavTop: TPanel
                Left = 0
                Top = 0
                Width = 952
                Height = 80
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                object lblWavFormat: TLabel
                  Transparent = True
                  Left = 8
                  Top = 46
                  Width = 68
                  Height = 15
                  Caption = 'Write format'
                end
                object chkWavLoop: TCheckBox
                  Left = 8
                  Top = 14
                  Width = 60
                  Height = 17
                  Caption = 'Loop'
                  TabOrder = 0
                end
                object cboWavFormat: TComboBox
                  Left = 84
                  Top = 42
                  Width = 170
                  Height = 23
                  Style = csDropDownList
                  TabOrder = 1
                end
              end
              object memWav: TMemo
                Left = 0
                Top = 80
                Width = 952
                Height = 451
                Align = alClient
                Font.Charset = DEFAULT_CHARSET
                Font.Color = clWindowText
                Font.Height = -12
                Font.Name = 'Consolas'
                Font.Style = []
                ParentFont = False
                PopupMenu = pmWav
                ReadOnly = True
                ScrollBars = ssBoth
                TabOrder = 1
                WordWrap = False
              end
            end
            object tabSecure: TTabSheet
              Caption = 'Secure Storage'
              ImageIndex = 10
              PopupMenu = pmSecure
              object lblSecureProvider: TLabel
                Transparent = True
                Left = 12
                Top = 12
                Width = 90
                Height = 15
                Caption = 'Provider: (none)'
              end
              object lblKey: TLabel
                Transparent = True
                Left = 12
                Top = 48
                Width = 22
                Height = 15
                Caption = 'Key'
              end
              object lblValue: TLabel
                Transparent = True
                Left = 12
                Top = 80
                Width = 30
                Height = 15
                Caption = 'Value'
              end
              object edtKey: TEdit
                Left = 64
                Top = 44
                Width = 300
                Height = 23
                TabOrder = 0
                Text = 'openai.api_key'
              end
              object edtValue: TEdit
                Left = 64
                Top = 76
                Width = 300
                Height = 23
                TabOrder = 1
              end
              object btnSecStore: TButton
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
              object btnSecRead: TButton
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
              object btnSecDelete: TButton
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
              object chkSecReveal: TCheckBox
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
              object btnSecSeal: TButton
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
              object btnSecVerify: TButton
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
              object btnSecProbe: TButton
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
              object memSecure: TMemo
                Left = 12
                Top = 156
                Width = 654
                Height = 354
                Font.Charset = DEFAULT_CHARSET
                Font.Color = clWindowText
                Font.Height = -12
                Font.Name = 'Consolas'
                Font.Style = []
                ParentFont = False
                ReadOnly = True
                ScrollBars = ssVertical
                TabOrder = 10
              end
            end
            object tabMP3: TTabSheet
              Caption = 'MP3'
              ImageIndex = 13
              object pnlMp3Top: TPanel
                Left = 0
                Top = 0
                Width = 952
                Height = 36
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                object lblMp3Bitrate: TLabel
                  Transparent = True
                  Left = 8
                  Top = 10
                  Width = 96
                  Height = 15
                  Caption = 'Export kbps (CBR)'
                end
                object cboMp3Bitrate: TComboBox
                  Left = 116
                  Top = 6
                  Width = 90
                  Height = 23
                  Style = csDropDownList
                  TabOrder = 0
                end
              end
              object memMp3: TMemo
                Left = 0
                Top = 36
                Width = 952
                Height = 495
                Align = alClient
                PopupMenu = pmMp3
                Font.Charset = DEFAULT_CHARSET
                Font.Color = clWindowText
                Font.Height = -12
                Font.Name = 'Consolas'
                Font.Style = []
                ParentFont = False
                ReadOnly = True
                ScrollBars = ssBoth
                TabOrder = 1
                WordWrap = False
              end
            end
            object tabMP4: TTabSheet
              Caption = 'MP4'
              ImageIndex = 14
              object pnlMp4Top: TPanel
                Left = 0
                Top = 0
                Width = 952
                Height = 80
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                object lblMp4Fmt: TLabel
                  Transparent = True
                  Left = 8
                  Top = 46
                  Width = 84
                  Height = 15
                  Caption = 'Export PCM as'
                end
                object cboMp4Fmt: TComboBox
                  Left = 100
                  Top = 42
                  Width = 120
                  Height = 23
                  Style = csDropDownList
                  TabOrder = 0
                end
              end
              object memMp4: TMemo
                Left = 0
                Top = 80
                Width = 952
                Height = 451
                Align = alClient
                Font.Charset = DEFAULT_CHARSET
                Font.Color = clWindowText
                Font.Height = -12
                Font.Name = 'Consolas'
                Font.Style = []
                ParentFont = False
                PopupMenu = pmMp4
                ReadOnly = True
                ScrollBars = ssBoth
                TabOrder = 1
                WordWrap = False
              end
            end
            object tabScope: TTabSheet
              Caption = 'Scope'
              object pnlScopeTop: TPanel
                Left = 0
                Top = 0
                Width = 952
                Height = 72
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                object lblScopeSignal: TLabel
                  Transparent = True
                  Left = 8
                  Top = 6
                  Width = 32
                  Height = 15
                  Caption = 'Signal'
                end
                object lblScopeMode: TLabel
                  Transparent = True
                  Left = 200
                  Top = 6
                  Width = 22
                  Height = 15
                  Caption = 'View'
                end
                object cboScopeSignal: TComboBox
                  Left = 8
                  Top = 22
                  Width = 180
                  Height = 23
                  Style = csDropDownList
                  TabOrder = 0
                end
                object cboScopeMode: TComboBox
                  Left = 200
                  Top = 22
                  Width = 180
                  Height = 23
                  Style = csDropDownList
                  TabOrder = 1
                end
                object chkScopeLive: TCheckBox
                  Left = 512
                  Top = 24
                  Width = 90
                  Height = 17
                  Caption = 'Live'
                  TabOrder = 3
                  OnClick = chkScopeLiveClick
                end
              end
              object pnlScopeReadout: TPanel
                Left = 0
                Top = 381
                Width = 952
                Height = 150
                Align = alBottom
                BevelOuter = bvNone
                TabOrder = 1
                object memScopeReadout: TMemo
                  Left = 0
                  Top = 0
                  Width = 952
                  Height = 150
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
              object pbScope: TPaintBox
                Left = 0
                Top = 72
                Width = 952
                Height = 309
                Align = alClient
                PopupMenu = pmScope
                OnPaint = pbScopePaint
              end
            end
            object tabAdvDsp: TTabSheet
              Caption = 'Advanced DSP'
              object pnlAdvDspTop: TPanel
                Left = 0
                Top = 0
                Width = 952
                Height = 72
                Align = alTop
                BevelOuter = bvNone
                TabOrder = 0
                object lblAdvDspSignal: TLabel
                  Transparent = True
                  Left = 8
                  Top = 6
                  Width = 32
                  Height = 15
                  Caption = 'Signal'
                end
                object lblAdvDspProcess: TLabel
                  Transparent = True
                  Left = 200
                  Top = 6
                  Width = 40
                  Height = 15
                  Caption = 'Process'
                end
                object lblAdvDspParam: TLabel
                  Transparent = True
                  Left = 452
                  Top = 6
                  Width = 100
                  Height = 15
                  Caption = 'Stretch / semitones'
                end
                object cboAdvDspSignal: TComboBox
                  Left = 8
                  Top = 22
                  Width = 180
                  Height = 23
                  Style = csDropDownList
                  TabOrder = 0
                end
                object cboAdvDspProcess: TComboBox
                  Left = 200
                  Top = 22
                  Width = 240
                  Height = 23
                  Style = csDropDownList
                  TabOrder = 1
                end
                object edtAdvDspParam: TEdit
                  Left = 452
                  Top = 22
                  Width = 100
                  Height = 23
                  TabOrder = 2
                  Text = '2.0'
                end
              end
              object memAdvDspReadout: TMemo
                Left = 0
                Top = 72
                Width = 952
                Height = 459
                Align = alClient
                Font.Charset = DEFAULT_CHARSET
                Font.Color = clWindowText
                Font.Height = -12
                Font.Name = 'Consolas'
                Font.Style = []
                ParentFont = False
                PopupMenu = pmAdvDsp
                ReadOnly = True
                ScrollBars = ssVertical
                TabOrder = 1
              end
            end
          end
        end
      end
    end
    object tabBrowser: TTabSheet
      Caption = 'Browser'
      ImageIndex = 17
      object pnlBrowserTop: TPanel
        Left = 0
        Top = 0
        Width = 952
        Height = 58
        Align = alTop
        BevelOuter = bvNone
        TabOrder = 0
        object lblBrowserHint: TLabel
          Transparent = True
          Left = 8
          Top = 38
          Width = 500
          Height = 15
          Caption = 'Select a Timeline audio channel, then add at the playhead; drag also works'
        end
        object btnBrowserAddFolder: TButton
          Left = 8
          Top = 6
          Width = 110
          Height = 25
          Caption = 'Add folder...'
          TabOrder = 0
          OnClick = btnBrowserAddFolderClick
        end
        object btnBrowserRefresh: TButton
          Left = 124
          Top = 6
          Width = 60
          Height = 25
          Caption = 'Refresh'
          TabOrder = 1
          OnClick = btnBrowserRefreshClick
        end
        object btnBrowserImport: TButton
          Left = 190
          Top = 6
          Width = 60
          Height = 25
          Caption = 'Import'
          TabOrder = 2
          OnClick = btnBrowserImportClick
        end
        object btnBrowserAddToSelected: TButton
          Left = 256
          Top = 6
          Width = 133
          Height = 25
          Caption = 'Add to selected track'
          TabOrder = 3
          OnClick = btnBrowserAddToSelectedClick
        end
      end
      object memBrowser: TMemo
        Left = 0
        Top = 390
        Width = 952
        Height = 141
        Align = alBottom
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clWindowText
        Font.Height = -12
        Font.Name = 'Consolas'
        Font.Style = []
        ParentFont = False
        ReadOnly = True
        ScrollBars = ssVertical
        TabOrder = 1
        WordWrap = False
      end
      object tvBrowser: TTreeView
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
      object lblBrowserFloating: TLabel
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
    object tabAI: TTabSheet
      Caption = 'AI'
      object pcAiMain: TPageControl
        Left = 0
        Top = 0
        Width = 952
        Height = 380
        Align = alTop
        TabOrder = 0
        object tsAiSelect: TTabSheet
          Caption = 'AI Selection'
          object lblAiProvider: TLabel
            Transparent = True
            Left = 8
            Top = 6
            Width = 40
            Height = 15
            Caption = 'Provider'
          end
          object lblAiKey: TLabel
            Transparent = True
            Left = 200
            Top = 6
            Width = 40
            Height = 15
            Caption = 'API key'
          end
          object lblAiModel: TLabel
            Transparent = True
            Left = 520
            Top = 6
            Width = 31
            Height = 15
            Caption = 'Model'
          end
          object cboAiProvider: TComboBox
            Left = 8
            Top = 22
            Width = 180
            Height = 23
            Style = csDropDownList
            TabOrder = 0
            OnChange = cboAiProviderChange
          end
          object edtAiApiKey: TEdit
            Left = 200
            Top = 22
            Width = 300
            Height = 23
            PasswordChar = '*'
            TabOrder = 1
          end
          object cboAiModel: TComboBox
            Left = 520
            Top = 22
            Width = 280
            Height = 23
            TabOrder = 2
            OnChange = cboAiModelChange
          end
          object btnAiTest: TButton
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
          object btnAiSave: TButton
            Left = 8
            Top = 50
            Width = 90
            Height = 25
            Caption = 'Save Key'
            TabOrder = 4
            OnClick = btnAiSaveClick
          end
          object btnAiDelete: TButton
            Left = 104
            Top = 50
            Width = 90
            Height = 25
            Caption = 'Delete Key'
            TabOrder = 5
            OnClick = btnAiDeleteClick
          end
        end
        object tsAiMcp: TTabSheet
          Caption = 'MCP'
          object lblAiMcpName: TLabel
            Transparent = True
            Left = 8
            Top = 8
            Width = 62
            Height = 15
            Caption = 'MCP name'
          end
          object lblAiMcpCmd: TLabel
            Transparent = True
            Left = 200
            Top = 8
            Width = 106
            Height = 15
            Caption = 'MCP command line'
          end
          object edtAiMcpName: TEdit
            Left = 8
            Top = 24
            Width = 180
            Height = 23
            TabOrder = 0
          end
          object edtAiMcpCommand: TEdit
            Left = 200
            Top = 24
            Width = 392
            Height = 23
            TabOrder = 1
          end
          object lblAiMcpToken: TLabel
            Transparent = True
            Left = 690
            Top = 8
            Width = 80
            Height = 15
            Caption = 'HTTP auth token'
          end
          object edtAiMcpToken: TEdit
            Left = 684
            Top = 24
            Width = 200
            Height = 23
            PasswordChar = '*'
            TabOrder = 20
          end
          object btnAiMcpTest: TButton
            Left = 600
            Top = 23
            Width = 75
            Height = 25
            Caption = 'Test'
            TabOrder = 2
            OnClick = btnAiMcpTestClick
          end
          object lblAiMcpHint: TLabel
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
          object chkAiMcpExpose: TCheckBox
            Left = 8
            Top = 78
            Width = 260
            Height = 19
            Caption = 'Expose UDAW as an MCP server'
            TabOrder = 3
            OnClick = chkAiMcpExposeClick
          end
          object lblAiMcpExposePort: TLabel
            Transparent = True
            Left = 276
            Top = 80
            Width = 24
            Height = 15
            Caption = 'Port'
          end
          object edtAiMcpExposePort: TEdit
            Left = 304
            Top = 76
            Width = 60
            Height = 23
            TabOrder = 4
            Text = '8765'
          end
          object chkAiMcpAllowDestructive: TCheckBox
            Left = 380
            Top = 78
            Width = 220
            Height = 19
            Caption = 'Allow destructive tools'
            TabOrder = 5
          end
          object lblAiMcpBind: TLabel
            Transparent = True
            Left = 608
            Top = 80
            Width = 28
            Height = 15
            Caption = 'Bind'
          end
          object edtAiMcpBind: TEdit
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
          object chkAiMcpTls: TCheckBox
            Left = 8
            Top = 110
            Width = 210
            Height = 19
            Caption = 'HTTPS (TLS) for remote agents'
            Hint = 'Adds an encrypted https listener next to the local one, for AI agents outside your network. Needs an auth token (always on), a PEM certificate + key, and a port-forward / tunnel to this PC.'
            ParentShowHint = False
            ShowHint = True
            TabOrder = 8
          end
          object lblAiMcpTlsPort: TLabel
            Transparent = True
            Left = 226
            Top = 112
            Width = 44
            Height = 15
            Caption = 'TLS port'
          end
          object edtAiMcpTlsPort: TEdit
            Left = 274
            Top = 108
            Width = 56
            Height = 23
            TabOrder = 9
            Text = '8766'
          end
          object lblAiMcpCert: TLabel
            Transparent = True
            Left = 342
            Top = 112
            Width = 60
            Height = 15
            Caption = 'Cert (PEM)'
          end
          object edtAiMcpCert: TEdit
            Left = 406
            Top = 108
            Width = 210
            Height = 23
            TabOrder = 10
          end
          object lblAiMcpKey: TLabel
            Transparent = True
            Left = 626
            Top = 112
            Width = 56
            Height = 15
            Caption = 'Key (PEM)'
          end
          object edtAiMcpKey: TEdit
            Left = 686
            Top = 108
            Width = 210
            Height = 23
            TabOrder = 11
          end
          object btnAiMcpTestLocal: TButton
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
          object btnAiMcpTestTls: TButton
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
          object edtAiMcpTestUrl: TEdit
            Left = 284
            Top = 139
            Width = 320
            Height = 23
            TextHint = 'https://your-host.example.com:8766/mcp  (blank = local https listener)'
            TabOrder = 14
          end
          object chkAiMcpSelfSigned: TCheckBox
            Left = 612
            Top = 141
            Width = 260
            Height = 19
            Caption = 'Allow self-signed certificate (test only)'
            TabOrder = 15
          end
          object memAiMcpProviders: TMemo
            Left = 8
            Top = 170
            Width = 936
            Height = 66
            ReadOnly = True
            ScrollBars = ssVertical
            TabOrder = 16
            Lines.Strings = (
              'Remote MCP - which AI providers can reach a UDAW MCP server (verified against provider docs, 2026-09-21):'
              'Claude (Anthropic Messages API "MCP connector", beta): YES - needs a PUBLIC https URL, Streamable HTTP or SSE, token via authorization_token, tools only. Local/LAN and stdio servers cannot be used.'
              'OpenAI (Responses API remote MCP tool): YES - needs a PUBLIC URL, Streamable HTTP or SSE, token via the authorization field; asks for approval unless require_approval = never.'
              'DeepSeek: NO hosted MCP connector in its API; only DeepSeek-Harness (a separate agent app) can use an https MCP endpoint as a client. Suno / Luma: not agents - N/A.'
              'Provider servers must be able to reach you and must trust your certificate: use a CA-signed cert (Let''s Encrypt) or a tunnel (Cloudflare/ngrok); a self-signed cert only works for your own tests.')
          end
          object lstAiMcpServers: TListBox
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
        object tsAiRecordings: TTabSheet
          Caption = 'Recordings'
          object lblSunoRefHint: TLabel
            Transparent = True
            Left = 8
            Top = 8
            Width = 900
            Height = 15
            Caption = 'Recordings available to Suno as reference audio for Cover/Extend (Generation tab). Add existing files or record new ones here.'
          end
          object lstSunoRefs: TListBox
            Left = 8
            Top = 32
            Width = 560
            Height = 300
            ItemHeight = 15
            TabOrder = 0
          end
          object btnSunoRefAdd: TButton
            Left = 580
            Top = 32
            Width = 150
            Height = 25
            Caption = 'Add Recording...'
            TabOrder = 1
            OnClick = btnSunoRefAddClick
          end
          object btnSunoRefRemove: TButton
            Left = 580
            Top = 64
            Width = 150
            Height = 25
            Caption = 'Remove'
            TabOrder = 2
            OnClick = btnSunoRefRemoveClick
          end
          object btnSunoRefRefresh: TButton
            Left = 580
            Top = 96
            Width = 150
            Height = 25
            Caption = 'Refresh from Folder'
            TabOrder = 3
            OnClick = btnSunoRefRefreshClick
          end
          object btnSunoRefRecord: TButton
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
        object tsAiLyrics: TTabSheet
          Caption = 'Lyrics and Styles'
          object lblSunoPrompt: TLabel
            Transparent = True
            Left = 8
            Top = 10
            Width = 70
            Height = 15
            Caption = 'Suno prompt'
          end
          object lblSunoLyricsCount: TLabel
            Transparent = True
            Left = 180
            Top = 206
            Width = 120
            Height = 15
            Caption = '0 / 5000 characters'
            Visible = False
          end
          object lblSunoStyle: TLabel
            Left = 8
            Top = 233
            Anchors = [akLeft, akBottom]
            Caption = 'Style / BPM'
            Visible = False
          end
          object lblSunoTitle: TLabel
            Left = 8
            Top = 326
            Anchors = [akLeft, akBottom]
            Caption = 'Title'
            Visible = False
          end
          object edtSunoPrompt: TEdit
            Left = 88
            Top = 7
            Width = 640
            Height = 23
            Anchors = [akLeft, akTop, akRight]
            TabOrder = 0
          end
          object memSunoLyrics: TRichEdit
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
          object chkSunoInstrumental: TCheckBox
            Left = 740
            Top = 9
            Anchors = [akTop, akRight]
            Width = 100
            Height = 19
            Caption = 'Instrumental'
            TabOrder = 2
          end
          object chkSunoCustom: TCheckBox
            Left = 8
            Top = 204
            Anchors = [akLeft, akBottom]
            Width = 160
            Height = 19
            Caption = 'Custom lyrics/style'
            TabOrder = 3
            OnClick = chkSunoCustomClick
          end
          object edtSunoStyle: TRichEdit
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
          object edtSunoTitle: TEdit
            Left = 88
            Top = 322
            Anchors = [akLeft, akBottom]
            Width = 300
            Height = 23
            TabOrder = 5
            Visible = False
          end
        end
        object tsAiGeneration: TTabSheet
          Caption = 'Generation'
          object pnlAiChat: TPanel
            Left = 0
            Top = 0
            Width = 952
            Height = 74
            Align = alTop
            BevelOuter = bvNone
            TabOrder = 0
            object edtAiPrompt: TEdit
              Left = 8
              Top = 8
              Width = 680
              Height = 23
              TabOrder = 0
            end
            object btnAiSend: TButton
              Left = 696
              Top = 7
              Width = 75
              Height = 25
              Caption = 'Send'
              Default = True
              TabOrder = 1
              OnClick = btnAiSendClick
            end
            object btnAiClear: TButton
              Left = 776
              Top = 7
              Width = 75
              Height = 25
              Caption = 'Clear'
              TabOrder = 2
              OnClick = btnAiClearClick
            end
            object btnAiGenerateTune: TButton
              Left = 8
              Top = 40
              Width = 280
              Height = 25
              Caption = 'Generate Tune from Browser Library'
              Hint = 'Ask the AI to plan and build a full timeline arrangement using files from your Browser folders'
              ShowHint = True
              ParentShowHint = False
              TabOrder = 3
              OnClick = btnAiGenerateTuneClick
            end
          end
          object pnlAiLuma: TPanel
            Left = 0
            Top = 0
            Width = 952
            Height = 276
            Align = alTop
            BevelOuter = bvNone
            TabOrder = 2
            Visible = False
            object lblLumaKind: TLabel
              Transparent = True
              Left = 8
              Top = 14
              Caption = 'Media type'
            end
            object cboLumaKind: TComboBox
              Left = 124
              Top = 10
              Width = 120
              Height = 23
              Style = csDropDownList
              ItemIndex = 0
              TabOrder = 0
              Items.Strings = (
                'Video'
                'Image')
              OnChange = cboLumaKindChange
            end
            object lblLumaModel: TLabel
              Transparent = True
              Left = 260
              Top = 14
              Caption = 'Model'
            end
            object cboLumaModel: TComboBox
              Left = 304
              Top = 10
              Width = 150
              Height = 23
              Style = csDropDownList
              ItemIndex = 0
              TabOrder = 1
              Items.Strings = (
                'ray-2'
                'ray-flash-2')
            end
            object btnLumaTest: TButton
              Left = 470
              Top = 9
              Width = 130
              Height = 25
              Caption = 'Test (credits)'
              TabOrder = 2
              OnClick = btnLumaTestClick
            end
            object lblLumaPrompt: TLabel
              Transparent = True
              Left = 8
              Top = 46
              Caption = 'Prompt'
            end
            object edtLumaPrompt: TEdit
              Left = 124
              Top = 42
              Width = 560
              Height = 23
              Hint = 'Describe the video or image to generate.'
              ShowHint = True
              TabOrder = 3
            end
            object lblLumaAspect: TLabel
              Transparent = True
              Left = 8
              Top = 78
              Caption = 'Aspect ratio'
            end
            object cboLumaAspect: TComboBox
              Left = 124
              Top = 74
              Width = 80
              Height = 23
              Style = csDropDownList
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
            object lblLumaResolution: TLabel
              Transparent = True
              Left = 224
              Top = 78
              Caption = 'Resolution'
            end
            object cboLumaResolution: TComboBox
              Left = 290
              Top = 74
              Width = 80
              Height = 23
              Style = csDropDownList
              ItemIndex = 1
              TabOrder = 5
              Items.Strings = (
                '540p'
                '720p'
                '1080p'
                '4k')
            end
            object lblLumaDuration: TLabel
              Transparent = True
              Left = 388
              Top = 78
              Caption = 'Duration'
            end
            object cboLumaDuration: TComboBox
              Left = 444
              Top = 74
              Width = 60
              Height = 23
              Style = csDropDownList
              ItemIndex = 0
              TabOrder = 6
              Items.Strings = (
                '5s'
                '9s')
            end
            object lblLumaFormat: TLabel
              Transparent = True
              Left = 224
              Top = 78
              Caption = 'Format'
            end
            object cboLumaFormat: TComboBox
              Left = 290
              Top = 74
              Width = 80
              Height = 23
              Style = csDropDownList
              ItemIndex = 0
              TabOrder = 7
              Items.Strings = (
                'jpg'
                'png')
            end
            object chkLumaLoop: TCheckBox
              Left = 524
              Top = 76
              Width = 60
              Height = 17
              Caption = 'Loop'
              TabOrder = 8
            end
            object lblLumaStartFrame: TLabel
              Transparent = True
              Left = 8
              Top = 110
              Caption = 'Start frame'
            end
            object edtLumaStartFrame: TEdit
              Left = 124
              Top = 106
              Width = 560
              Height = 23
              Hint = 'Public HTTPS image URL (Luma only accepts CDN/web URLs, not local files).'
              ShowHint = True
              TabOrder = 9
            end
            object lblLumaEndFrame: TLabel
              Transparent = True
              Left = 8
              Top = 142
              Caption = 'End frame'
            end
            object edtLumaEndFrame: TEdit
              Left = 124
              Top = 138
              Width = 560
              Height = 23
              Hint = 'Public HTTPS image URL (Luma only accepts CDN/web URLs, not local files).'
              ShowHint = True
              TabOrder = 10
            end
            object lblLumaImageRef: TLabel
              Transparent = True
              Left = 8
              Top = 110
              Caption = 'Image reference'
            end
            object edtLumaImageRef: TEdit
              Left = 124
              Top = 106
              Width = 560
              Height = 23
              Hint = 'Public HTTPS image URL (Luma only accepts CDN/web URLs, not local files).'
              ShowHint = True
              TabOrder = 11
            end
            object lblLumaImageRefWeight: TLabel
              Transparent = True
              Left = 696
              Top = 78
              Caption = 'Ref. weight'
            end
            object edtLumaImageRefWeight: TEdit
              Left = 696
              Top = 106
              Width = 50
              Height = 23
              Hint = 'Influence 0.0 - 1.0'
              ShowHint = True
              TabOrder = 12
              Text = '0.85'
            end
            object lblLumaStyleRef: TLabel
              Transparent = True
              Left = 8
              Top = 142
              Caption = 'Style reference'
            end
            object edtLumaStyleRef: TEdit
              Left = 124
              Top = 138
              Width = 560
              Height = 23
              Hint = 'Public HTTPS image URL (Luma only accepts CDN/web URLs, not local files).'
              ShowHint = True
              TabOrder = 13
            end
            object edtLumaStyleWeight: TEdit
              Left = 696
              Top = 138
              Width = 50
              Height = 23
              Hint = 'Influence 0.0 - 1.0'
              ShowHint = True
              TabOrder = 14
              Text = '0.8'
            end
            object lblLumaCharRef: TLabel
              Transparent = True
              Left = 8
              Top = 174
              Caption = 'Character reference'
            end
            object edtLumaCharRef: TEdit
              Left = 124
              Top = 170
              Width = 560
              Height = 23
              Hint = 'Public HTTPS URL of a face/character image (identity0).'
              ShowHint = True
              TabOrder = 15
            end
            object lblLumaModifyRef: TLabel
              Transparent = True
              Left = 8
              Top = 206
              Caption = 'Modify image'
            end
            object edtLumaModifyRef: TEdit
              Left = 124
              Top = 202
              Width = 560
              Height = 23
              Hint = 'Public HTTPS URL of an image to modify with the prompt.'
              ShowHint = True
              TabOrder = 16
            end
            object edtLumaModifyWeight: TEdit
              Left = 696
              Top = 202
              Width = 50
              Height = 23
              Hint = 'Closeness to input 0.0 - 1.0 (use 0.0-0.1 for colour changes)'
              ShowHint = True
              TabOrder = 17
              Text = '1.0'
            end
            object lblLumaConcepts: TLabel
              Transparent = True
              Left = 8
              Top = 174
              Caption = 'Camera concepts'
            end
            object lstLumaConcepts: TListBox
              Left = 124
              Top = 170
              Width = 440
              Height = 60
              ItemHeight = 15
              MultiSelect = True
              TabOrder = 20
            end
            object btnLumaConcepts: TButton
              Left = 572
              Top = 170
              Width = 112
              Height = 25
              Caption = 'Load concepts'
              TabOrder = 21
              OnClick = btnLumaConceptsClick
            end
            object btnLumaOpen: TButton
              Left = 219
              Top = 240
              Width = 110
              Height = 25
              Caption = 'Open result'
              Enabled = False
              TabOrder = 22
              OnClick = btnLumaOpenClick
            end
            object btnLumaGenerate: TButton
              Left = 8
              Top = 240
              Width = 120
              Height = 25
              Caption = 'Generate'
              TabOrder = 18
              OnClick = btnLumaGenerateClick
            end
            object chkLumaTabOnly: TCheckBox
              Left = 224
              Top = 244
              Width = 300
              Height = 17
              Caption = 'Music Tabular Only (PDF to AI\Rendered)'
              TabOrder = 20
            end
            object btnLumaCancel: TButton
              Left = 136
              Top = 240
              Width = 75
              Height = 25
              Caption = 'Cancel'
              TabOrder = 19
              OnClick = btnLumaCancelClick
            end
          end
          object pnlAiSuno: TPanel
            Left = 0
            Top = 74
            Width = 952
            Height = 180
            Align = alTop
            BevelOuter = bvNone
            TabOrder = 1
            object lblSunoBaseUrl: TLabel
              Transparent = True
              Left = 8
              Top = 13
              Width = 70
              Height = 15
              Caption = 'Suno proxy'
            end
            object edtSunoBaseUrl: TEdit
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
            object btnSunoTest: TButton
              Left = 396
              Top = 9
              Width = 75
              Height = 25
              Caption = 'Test'
              TabOrder = 1
              OnClick = btnSunoTestClick
            end
            object lblSunoApi: TLabel
              Left = 8
              Top = 46
              Caption = 'API type'
            end
            object cboSunoApi: TComboBox
              Left = 88
              Top = 42
              Width = 240
              Height = 23
              Style = csDropDownList
              ItemIndex = 1
              Enabled = False
              Items.Strings = (
                'Self-hosted gcui-art/suno-api'
                'Managed SunoAPI.org')
              TabOrder = 2
              OnChange = cboSunoApiChange
            end
            object lblSunoModel: TLabel
              Left = 340
              Top = 46
              Caption = 'Model'
            end
            object cboSunoModel: TComboBox
              Left = 390
              Top = 42
              Width = 120
              Height = 23
              Style = csDropDownList
              Hint = 'AI model version. V6 is SunoAPI.org'#39's current standard/recommended default. V6_WILD/V6_MINI are current experimental/lightweight variants. Everything below the separator is deprecated - kept only for accounts still on an older tier.'
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
            object chkSunoAdvanced: TCheckBox
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
            object lblSunoCallback: TLabel
              Left = 8
              Top = 78
              Caption = 'Callback URL'
            end
            object edtSunoCallback: TEdit
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
            object lblSunoRefMode: TLabel
              Left = 8
              Top = 110
              Caption = 'Ref Audio'
            end
            object cboSunoRefMode: TComboBox
              Left = 88
              Top = 106
              Width = 170
              Height = 23
              Style = csDropDownList
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
            object lblSunoContinueAt: TLabel
              Left = 270
              Top = 110
              Caption = 'Continue at (s)'
              Visible = False
            end
            object edtSunoContinueAt: TEdit
              Left = 360
              Top = 106
              Width = 70
              Height = 23
              TabOrder = 7
              Text = '0'
              Visible = False
            end
            object btnSunoGenerate: TButton
              Left = 8
              Top = 144
              Width = 85
              Height = 25
              Caption = 'Generate'
              TabOrder = 8
              OnClick = btnSunoGenerateClick
            end
            object btnSunoCancel: TButton
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
      object pnlAiVoice: TPanel
        Left = 0
        Top = 380
        Width = 952
        Height = 40
        Align = alTop
        BevelOuter = bvNone
        TabOrder = 1
        object lblVoiceHint: TLabel
          Transparent = True
          Left = 8
          Top = 10
          Width = 500
          Height = 15
          Caption = 'Voice command: records ~4s from the input device, transcribes, then acts or chats'
        end
      end
      object splAiLog: TSplitter
        Left = 0
        Top = 420
        Width = 952
        Height = 5
        Cursor = crVSplit
        Align = alTop
        MinSize = 60
      end
      object memAiLog: TMemo
        Left = 0
        Top = 425
        Width = 952
        Height = 186
        Align = alClient
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clWindowText
        Font.Height = -12
        Font.Name = 'Consolas'
        Font.Style = []
        ParentFont = False
        PopupMenu = pmAi
        ReadOnly = True
        ScrollBars = ssVertical
        TabOrder = 2
      end
    end
  end
  object stbMain: TStatusBar
    Left = 0
    Top = 601
    Width = 960
    Height = 19
    Panels = <>
    SimplePanel = True
  end
  object prgStatus: TProgressBar
    Left = 784
    Top = 602
    Width = 170
    Height = 16
    Anchors = [akRight, akBottom]
    Min = 0
    Max = 100
    TabStop = False
    Visible = False
  end
  object pnlLogView: TPanel
    Left = 0
    Top = 0
    Width = 952
    Height = 531
    Visible = False
    BevelOuter = bvNone
    object lvLog: TListView
      Left = 0
      Top = 0
      Width = 952
      Height = 490
      Align = alClient
      PopupMenu = pmLog
      OnCustomDrawItem = lvLogCustomDrawItem
      Columns = <
        item
          Caption = 'Time'
          Width = 110
        end
        item
          Caption = 'Level'
          Width = 70
        end
        item
          Caption = 'Subsystem'
          Width = 110
        end
        item
          Caption = 'Message'
          Width = 640
        end>
      ReadOnly = True
      RowSelect = True
      TabOrder = 0
      ViewStyle = vsReport
    end
    object pnlLogButtons: TPanel
      Left = 0
      Top = 490
      Width = 952
      Height = 41
      Align = alBottom
      BevelOuter = bvNone
      TabOrder = 1
      object cboLevel: TComboBox
        Left = 8
        Top = 9
        Width = 110
        Height = 23
        Style = csDropDownList
        TabOrder = 0
        OnChange = btnApplyLevelClick
      end
    end
  end
  object tmrUI: TTimer
    Interval = 500
    OnTimer = tmrUITimer
    Left = 880
    Top = 8
  end
  object dlgSaveProject: TSaveDialog
    DefaultExt = 'udawproj'
    Filter = 'UDAW project (*.udawproj)|*.udawproj|All files (*.*)|*.*'
    Left = 880
    Top = 48
  end
  object dlgOpenProject: TOpenDialog
    DefaultExt = 'udawproj'
    Filter = 'UDAW project (*.udawproj)|*.udawproj|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 880
    Top = 88
  end
  object dlgOpenWav: TOpenDialog
    DefaultExt = 'wav'
    Filter = 'WAV audio (*.wav)|*.wav|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 880
    Top = 128
  end
  object dlgSunoRefOpen: TOpenDialog
    DefaultExt = 'wav'
    Filter = 'Audio files (*.wav;*.mp3;*.flac)|*.wav;*.mp3;*.flac|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 880
    Top = 160
  end
  object dlgTimelineExport: TSaveDialog
    Filter = 'WAV - 24-bit stereo PCM|*.wav|MP3 - 320 kbps stereo|*.mp3|MP4 - AAC stereo audio|*.mp4|M4A - AAC stereo audio|*.m4a|Raw PCM - signed 16-bit stereo + metadata|*.pcm|FLAC - 24-bit lossless stereo|*.flac'
    Options = [ofOverwritePrompt, ofHideReadOnly, ofPathMustExist, ofEnableSizing]
    Title = 'Export complete timeline mix'
    Left = 280
    Top = 16
  end
  object dlgSaveWav: TSaveDialog
    DefaultExt = 'wav'
    Filter = 'WAV audio (*.wav)|*.wav|All files (*.*)|*.*'
    Left = 880
    Top = 168
  end
  object dlgSaveLyrics: TSaveDialog
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
      object pmSunoLyricsExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object dlgOpenVst: TOpenDialog
    DefaultExt = 'dll'
    Filter = 
      'Plugins (*.dll;*.clap;*.vst3)|*.dll;*.clap;*.vst3|VST2 plugin (*.dl' +
      'l)|*.dll|CLAP plugin (*.clap)|*.clap|VST3 plugin (*.vst3)|*.vst3|All' +
      ' files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 880
    Top = 264
  end
  object dlgOpenMod: TOpenDialog
    DefaultExt = 'mod'
    Filter = 'ProTracker module (*.mod)|*.mod|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 880
    Top = 208
  end
  object dlgSaveMod: TSaveDialog
    DefaultExt = 'mod'
    Filter = 'ProTracker module (*.mod)|*.mod|All files (*.*)|*.*'
    Left = 880
    Top = 248
  end
  object dlgOpenXm: TOpenDialog
    DefaultExt = 'xm'
    Filter = 'FastTracker 2 module (*.xm)|*.xm|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 816
    Top = 208
  end
  object dlgSaveXm: TSaveDialog
    DefaultExt = 'xm'
    Filter = 'FastTracker 2 module (*.xm)|*.xm|All files (*.*)|*.*'
    Left = 816
    Top = 248
  end
  object dlgOpenMptm: TOpenDialog
    DefaultExt = 'mptm'
    Filter = 'OpenMPT / IT module (*.mptm;*.it)|*.mptm;*.it|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 752
    Top = 208
  end
  object dlgSaveMptm: TSaveDialog
    DefaultExt = 'mptm'
    Filter = 'OpenMPT module (*.mptm)|*.mptm|All files (*.*)|*.*'
    Left = 752
    Top = 248
  end
  object dlgOpenMp3: TOpenDialog
    DefaultExt = 'mp3'
    Filter = 'MP3 audio (*.mp3)|*.mp3|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 688
    Top = 208
  end
  object dlgSaveMp3: TSaveDialog
    DefaultExt = 'mp3'
    Filter = 'MP3 audio (*.mp3)|*.mp3|All files (*.*)|*.*'
    Left = 688
    Top = 248
  end
  object dlgOpenMp4: TOpenDialog
    DefaultExt = 'mp4'
    Filter = 'MP4 audio (*.mp4;*.m4a)|*.mp4;*.m4a|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 688
    Top = 288
  end
  object dlgOpenFlac: TOpenDialog
    DefaultExt = 'flac'
    Filter = 'FLAC audio (*.flac)|*.flac|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 688
    Top = 368
  end
  object dlgOpenAls: TOpenDialog
    DefaultExt = 'als'
    Filter = 'Ableton Live Set (*.als)|*.als|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 688
    Top = 408
  end
  object dlgOpenFlp: TOpenDialog
    DefaultExt = 'flp'
    Filter = 'FL Studio Project (*.flp)|*.flp|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 688
    Top = 448
  end
  object dlgSaveMp4: TSaveDialog
    DefaultExt = 'mp4'
    Filter = 'MP4 audio (*.mp4;*.m4a)|*.mp4;*.m4a|All files (*.*)|*.*'
    Left = 688
    Top = 328
  end
  object dlgOpenMidi: TOpenDialog
    DefaultExt = 'mid'
    Filter = 'Standard MIDI File (*.mid;*.midi)|*.mid;*.midi|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Left = 760
    Top = 288
  end
  object dlgSaveMidi: TSaveDialog
    DefaultExt = 'mid'
    Filter = 'Standard MIDI File (*.mid;*.midi)|*.mid;*.midi|All files (*.*)|*.*'
    Left = 760
    Top = 328
  end
  object mnuMain: TMainMenu
    Left = 16
    Top = 16
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
        object mnuTrkSetCell: TMenuItem
          Caption = 'Set cell'
          OnClick = btnTrkSetCellClick
        end
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
      object mnuTrkEdit: TMenuItem
        Caption = 'Edit'
        object mnuTrkUndo: TMenuItem
          Caption = 'Undo'
          OnClick = btnTrkUndoClick
        end
        object mnuTrkRedo: TMenuItem
          Caption = 'Redo'
          OnClick = btnTrkRedoClick
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
      end
      object mnuTrkExport: TMenuItem
        Caption = 'Export'
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
    end
    object mnuMixer: TMenuItem
      Caption = 'Mixer'
      Visible = False
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
        object mnuMixDelInsert: TMenuItem
          Caption = 'Remove insert'
          OnClick = btnMixDelInsertClick
        end
      end
      object mnuMixEdit: TMenuItem
        Caption = 'Edit'
        object mnuMixUndo: TMenuItem
          Caption = 'Undo'
          OnClick = btnMixUndoClick
        end
        object mnuMixRedo: TMenuItem
          Caption = 'Redo'
          OnClick = btnMixRedoClick
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
      object mnuMidiEdit: TMenuItem
        Caption = 'Edit'
        object mnuMidiUndo: TMenuItem
          Caption = 'Undo'
          OnClick = btnMidiUndoClick
        end
        object mnuMidiRedo: TMenuItem
          Caption = 'Redo'
          OnClick = btnMidiRedoClick
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
        object mnuTlExportFlac: TMenuItem
          Caption = 'FLAC...'
          OnClick = pmTlExportFlacClick
        end
      end
      object mnuTlExportSep: TMenuItem
        Caption = '-'
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
      object mnuTlEdit: TMenuItem
        Caption = 'Edit'
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
          Caption = 'Cut clip'
          OnClick = btnTlCutClick
        end
        object mnuTlCopy: TMenuItem
          Caption = 'Copy clip'
          OnClick = btnTlCopyClick
        end
        object mnuTlPaste: TMenuItem
          Caption = 'Paste clip at playhead'
          OnClick = btnTlPasteClick
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
          Caption = 'Effects'
          object mnuTlFxAmplify: TMenuItem
            Tag = 12
            Caption = 'Amplify'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxAutoPan: TMenuItem
            Tag = 7
            Caption = 'Auto-Pan'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxBalance: TMenuItem
            Tag = 21
            Caption = 'Balance'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxBassEnhance: TMenuItem
            Tag = 22
            Caption = 'Bass Enhance'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxBitCrusher: TMenuItem
            Tag = 9
            Caption = 'Bit Crusher'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxBrightenEQ: TMenuItem
            Tag = 10
            Caption = 'Brighten (EQ)'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxChorus: TMenuItem
            Tag = 3
            Caption = 'Chorus'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxCompressor: TMenuItem
            Tag = 1
            Caption = 'Compressor'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxDCOffsetRemover: TMenuItem
            Tag = 23
            Caption = 'DC Offset Remover'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxDeEsser: TMenuItem
            Tag = 13
            Caption = 'De-Esser'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxDelay: TMenuItem
            Tag = 14
            Caption = 'Delay'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxExciter: TMenuItem
            Tag = 24
            Caption = 'Exciter'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxNoiseReduction: TMenuItem
            Tag = 35
            Caption = 'Noise Reduction...'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxAutoTune: TMenuItem
            Tag = 36
            Caption = 'Auto-Tune...'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxConvolutionReverb: TMenuItem
            Tag = 37
            Caption = 'Convolution Reverb...'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxSplitStems: TMenuItem
            Tag = 38
            Caption = 'Split Stems (Drums/Bass/Vocals/Other)'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxAudioToMidi: TMenuItem
            Tag = 39
            Caption = 'Audio to MIDI...'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxExpander: TMenuItem
            Tag = 15
            Caption = 'Expander'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxFadeIn: TMenuItem
            Caption = 'Fade In'
            OnClick = TlFxFadeInClick
          end
          object mnuTlFxFadeOut: TMenuItem
            Caption = 'Fade Out'
            OnClick = TlFxFadeOutClick
          end
          object mnuTlFxFlanger: TMenuItem
            Tag = 4
            Caption = 'Flanger'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxFoldback: TMenuItem
            Tag = 16
            Caption = 'Foldback'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxGate: TMenuItem
            Tag = 17
            Caption = 'Gate'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxHardClip: TMenuItem
            Tag = 18
            Caption = 'Hard Clip'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxHighPassFilter: TMenuItem
            Tag = 25
            Caption = 'High-Pass Filter'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxLimiter: TMenuItem
            Tag = 19
            Caption = 'Limiter'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxLowPassFilter: TMenuItem
            Tag = 26
            Caption = 'Low-Pass Filter'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxMakeMono: TMenuItem
            Tag = 27
            Caption = 'Make Mono'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxMultibandCompressor: TMenuItem
            Tag = 28
            Caption = 'Multiband Compressor'
            OnClick = TlFxMenuClick
          end
          object mnuTlNormalizeRange: TMenuItem
            Caption = 'Normalize'
            OnClick = btnTlNormalizeRangeClick
          end
          object mnuTlFxNotchFilter: TMenuItem
            Tag = 29
            Caption = 'Notch Filter'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxPhaser: TMenuItem
            Tag = 5
            Caption = 'Phaser'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxPingPongDelay: TMenuItem
            Tag = 20
            Caption = 'Ping-Pong Delay'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxPitchShift: TMenuItem
            Tag = 30
            Caption = 'Pitch Shift'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxPresenceBoost: TMenuItem
            Tag = 31
            Caption = 'Presence Boost'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxReverb: TMenuItem
            Tag = 2
            Caption = 'Reverb'
            OnClick = TlFxMenuClick
          end
          object mnuTlUndoEffect: TMenuItem
            Caption = 'Undo Effect'
            OnClick = TlUndoEffectClick
          end
          object mnuTlReverseRange: TMenuItem
            Caption = 'Reverse'
            OnClick = btnTlReverseRangeClick
          end
          object mnuTlFxSaturation: TMenuItem
            Tag = 8
            Caption = 'Saturation'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxSilence: TMenuItem
            Tag = 11
            Caption = 'Silence'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxStereoWidener: TMenuItem
            Tag = 32
            Caption = 'Stereo Widener'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxTransientShaper: TMenuItem
            Tag = 33
            Caption = 'Transient Shaper'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxTrebleBoost: TMenuItem
            Tag = 34
            Caption = 'Treble Boost'
            OnClick = TlFxMenuClick
          end
          object mnuTlFxTremolo: TMenuItem
            Tag = 6
            Caption = 'Tremolo'
            OnClick = TlFxMenuClick
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
    object mnuProject: TMenuItem
      Caption = 'Project'
      Visible = False
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
      object mnuProjectMetadata: TMenuItem
        Caption = 'Metadata'
        object mnuProjectApply: TMenuItem
          Caption = 'Apply metadata'
          OnClick = btnProjectApplyClick
        end
      end
      object mnuProjectEdit: TMenuItem
        Caption = 'Edit'
        object mnuProjectUndo: TMenuItem
          Caption = 'Undo'
          OnClick = btnUndoClick
        end
        object mnuProjectRedo: TMenuItem
          Caption = 'Redo'
          OnClick = btnRedoClick
        end
      end
      object mnuProjectGraph: TMenuItem
        Caption = 'Graph'
        object mnuProjectAddGainNode: TMenuItem
          Caption = 'Add gain node'
          OnClick = btnAddGainNodeClick
        end
        object mnuProjectRemoveLastNode: TMenuItem
          Caption = 'Remove last node'
          OnClick = btnRemoveLastNodeClick
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
      object mnuLogSep1: TMenuItem
        Caption = '-'
      end
      object mnuClearLogView: TMenuItem
        Caption = 'Clear view'
        OnClick = btnClearLogViewClick
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
      Caption = 'AI'
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
    object mnuHelp: TMenuItem
      Caption = 'Help'
      object mnuHelpAbout: TMenuItem
        Caption = 'UDAW Help Centre...'
        OnClick = btnHelpAboutClick
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
    Left = 56
    Top = 16
    object pmTrkGridShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmTrkSetCell: TMenuItem
      Caption = 'Set cell'
      OnClick = btnTrkSetCellClick
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
      object pmTrkGridExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmTrkGridExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmTrkGridExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmTrkGridExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object pmTrkSeq: TPopupMenu
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
      object pmTrkSeqExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmTrkSeqExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmTrkSeqExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmTrkSeqExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
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
    object pmMixDelInsert: TMenuItem
      Caption = 'Remove insert'
      OnClick = btnMixDelInsertClick
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
      object pmPianoRollExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object pmTimeline: TPopupMenu
    OnPopup = pmTimelinePopup
    Left = 216
    Top = 16
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
      object pmTlTrackUp: TMenuItem
        Caption = 'Move Channel Up'
        OnClick = btnTlTrackUpClick
      end
      object pmTlTrackDown: TMenuItem
        Caption = 'Move Channel Down'
        OnClick = btnTlTrackDownClick
      end
      object pmTlMuteTrack: TMenuItem
        Caption = 'Mute Channel'
        OnClick = pmTlMuteTrackClick
      end
      object pmTlRenameTrack: TMenuItem
        Caption = 'Rename Channel...'
        OnClick = pmTlRenameTrackClick
      end
      object pmTlSepChanB: TMenuItem
        Caption = '-'
      end
      object pmTlAddClip: TMenuItem
        Caption = 'Add clip from WAV...'
        OnClick = btnTlAddClipClick
      end
      object pmTlSplit: TMenuItem
        Caption = 'Split at playhead'
        OnClick = btnTlSplitClick
      end
      object pmTlDeleteClip: TMenuItem
        Caption = 'Remove Element'
        OnClick = btnTlDeleteClipClick
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
        object pmTlJumpElementStart: TMenuItem
          Caption = 'Start of Timeline'
          OnClick = pmTlJumpElementStartClick
        end
        object pmTlJumpElementEnd: TMenuItem
          Caption = 'End of Timeline'
          OnClick = pmTlJumpElementEndClick
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
        object pmTlLoopStart: TMenuItem
          Caption = 'Set Loop Start Here'
          OnClick = btnTlLoopStartClick
        end
        object pmTlLoopEnd: TMenuItem
          Caption = 'Set Loop End Here'
          OnClick = btnTlLoopEndClick
        end
        object pmTlLoopToggle: TMenuItem
          Caption = 'Loop Playback'
          OnClick = btnTlLoopToggleClick
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
      object pmTlImport: TMenuItem
        Caption = 'Import to Timeline'
        object pmTlImportWav: TMenuItem
          Caption = 'WAV / PCM File...'
          OnClick = mnuTlImportWavClick
        end
        object pmTlImportMp3: TMenuItem
          Caption = 'MP3 File...'
          OnClick = btnMp3ToTimelineClick
        end
        object pmTlImportMp4: TMenuItem
          Caption = 'MP4 / M4A File...'
          OnClick = btnMp4ToTimelineClick
        end
        object pmTlImportFlac: TMenuItem
          Caption = 'FLAC File...'
          OnClick = mnuTlImportFlacClick
        end
        object pmTlImportSep1: TMenuItem
          Caption = '-'
        end
        object pmTlImportMod: TMenuItem
          Caption = 'Tracker Module (.mod)...'
          OnClick = mnuTlImportModClick
        end
        object pmTlImportXm: TMenuItem
          Caption = 'FastTracker II (.xm)...'
          OnClick = mnuTlImportXmClick
        end
        object pmTlImportMptm: TMenuItem
          Caption = 'IT / MPTM (.it/.mptm)...'
          OnClick = mnuTlImportMptmClick
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
      object pmTlExport: TMenuItem
        Caption = 'Export'
        object pmTlExportWav: TMenuItem
          Caption = 'WAV...'
          OnClick = pmTlExportWavClick
        end
        object pmTlExportMp3: TMenuItem
          Caption = 'MP3...'
          OnClick = pmTlExportMp3Click
        end
        object pmTlExportMp4: TMenuItem
          Caption = 'MP4...'
          OnClick = pmTlExportMp4Click
        end
        object pmTlExportFlac: TMenuItem
          Caption = 'FLAC...'
          OnClick = pmTlExportFlacClick
        end
      end
      object pmTlSepChanG: TMenuItem
        Caption = '-'
      end
      object pmTimelineShowLog: TMenuItem
        Caption = 'Open Log...'
        OnClick = ShowLogClick
      end
      object pmTimelineOpenBrowser: TMenuItem
        Caption = 'Open Browser Window...'
        OnClick = OpenBrowserWindowClick
      end
    end
    object pmTlEditCat: TMenuItem
      Caption = 'Edit'
      object pmTlUndo: TMenuItem
        Caption = 'Undo'
        OnClick = btnTlUndoClick
      end
      object pmTlRedo: TMenuItem
        Caption = 'Redo'
        OnClick = btnTlRedoClick
      end
      object pmTlHistory: TMenuItem
        Caption = 'Undo/Redo History'
      end
      object pmTlSepEditA: TMenuItem
        Caption = '-'
      end
      object pmTlCut: TMenuItem
        Caption = 'Cut clip'
        OnClick = btnTlCutClick
      end
      object pmTlCopy: TMenuItem
        Caption = 'Copy clip'
        OnClick = btnTlCopyClick
      end
      object pmTlPaste: TMenuItem
        Caption = 'Paste clip at playhead'
        OnClick = btnTlPasteClick
      end
      object pmTlSepEditB: TMenuItem
        Caption = '-'
      end
      object pmTlCopySelection: TMenuItem
        Caption = 'Copy Selection'
        OnClick = pmTlCopySelectionClick
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
        object pmTlWarpSnap: TMenuItem
          Tag = 2
          Caption = 'Snap Marker to Nearest Beat'
          OnClick = TlWarpMenuClick
        end
        object pmTlWarpAuto: TMenuItem
          Tag = 3
          Caption = 'Auto-Detect Beats to Grid'
          OnClick = TlWarpMenuClick
        end
        object pmTlWarpApply: TMenuItem
          Tag = 4
          Caption = 'Apply Markers'
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
      end
      object pmTlSepEditD: TMenuItem
        Caption = '-'
      end
      object pmTlEffects: TMenuItem
        Caption = 'Effects'
        object pmTlFxAmplify: TMenuItem
          Tag = 12
          Caption = 'Amplify'
          OnClick = TlFxMenuClick
        end
        object pmTlFxAutoPan: TMenuItem
          Tag = 7
          Caption = 'Auto-Pan'
          OnClick = TlFxMenuClick
        end
        object pmTlFxBalance: TMenuItem
          Tag = 21
          Caption = 'Balance'
          OnClick = TlFxMenuClick
        end
        object pmTlFxBassEnhance: TMenuItem
          Tag = 22
          Caption = 'Bass Enhance'
          OnClick = TlFxMenuClick
        end
        object pmTlFxBitCrusher: TMenuItem
          Tag = 9
          Caption = 'Bit Crusher'
          OnClick = TlFxMenuClick
        end
        object pmTlFxBrightenEQ: TMenuItem
          Tag = 10
          Caption = 'Brighten (EQ)'
          OnClick = TlFxMenuClick
        end
        object pmTlFxChorus: TMenuItem
          Tag = 3
          Caption = 'Chorus'
          OnClick = TlFxMenuClick
        end
        object pmTlFxCompressor: TMenuItem
          Tag = 1
          Caption = 'Compressor'
          OnClick = TlFxMenuClick
        end
        object pmTlFxDCOffsetRemover: TMenuItem
          Tag = 23
          Caption = 'DC Offset Remover'
          OnClick = TlFxMenuClick
        end
        object pmTlFxDeEsser: TMenuItem
          Tag = 13
          Caption = 'De-Esser'
          OnClick = TlFxMenuClick
        end
        object pmTlFxDelay: TMenuItem
          Tag = 14
          Caption = 'Delay'
          OnClick = TlFxMenuClick
        end
        object pmTlFxExciter: TMenuItem
          Tag = 24
          Caption = 'Exciter'
          OnClick = TlFxMenuClick
        end
        object pmTlFxNoiseReduction: TMenuItem
          Tag = 35
          Caption = 'Noise Reduction...'
          OnClick = TlFxMenuClick
        end
        object pmTlFxAutoTune: TMenuItem
          Tag = 36
          Caption = 'Auto-Tune...'
          OnClick = TlFxMenuClick
        end
        object pmTlFxConvolutionReverb: TMenuItem
          Tag = 37
          Caption = 'Convolution Reverb...'
          OnClick = TlFxMenuClick
        end
        object pmTlFxSplitStems: TMenuItem
          Tag = 38
          Caption = 'Split Stems (Drums/Bass/Vocals/Other)'
          OnClick = TlFxMenuClick
        end
        object pmTlFxAudioToMidi: TMenuItem
          Tag = 39
          Caption = 'Audio to MIDI...'
          OnClick = TlFxMenuClick
        end
        object pmTlFxExpander: TMenuItem
          Tag = 15
          Caption = 'Expander'
          OnClick = TlFxMenuClick
        end
        object pmTlFxFadeIn: TMenuItem
          Caption = 'Fade In'
          OnClick = TlFxFadeInClick
        end
        object pmTlFxFadeOut: TMenuItem
          Caption = 'Fade Out'
          OnClick = TlFxFadeOutClick
        end
        object pmTlFxFlanger: TMenuItem
          Tag = 4
          Caption = 'Flanger'
          OnClick = TlFxMenuClick
        end
        object pmTlFxFoldback: TMenuItem
          Tag = 16
          Caption = 'Foldback'
          OnClick = TlFxMenuClick
        end
        object pmTlFxGate: TMenuItem
          Tag = 17
          Caption = 'Gate'
          OnClick = TlFxMenuClick
        end
        object pmTlFxHardClip: TMenuItem
          Tag = 18
          Caption = 'Hard Clip'
          OnClick = TlFxMenuClick
        end
        object pmTlFxHighPassFilter: TMenuItem
          Tag = 25
          Caption = 'High-Pass Filter'
          OnClick = TlFxMenuClick
        end
        object pmTlFxLimiter: TMenuItem
          Tag = 19
          Caption = 'Limiter'
          OnClick = TlFxMenuClick
        end
        object pmTlFxLowPassFilter: TMenuItem
          Tag = 26
          Caption = 'Low-Pass Filter'
          OnClick = TlFxMenuClick
        end
        object pmTlFxMakeMono: TMenuItem
          Tag = 27
          Caption = 'Make Mono'
          OnClick = TlFxMenuClick
        end
        object pmTlFxMultibandCompressor: TMenuItem
          Tag = 28
          Caption = 'Multiband Compressor'
          OnClick = TlFxMenuClick
        end
        object pmTlNormalizeRange: TMenuItem
          Caption = 'Normalize'
          OnClick = btnTlNormalizeRangeClick
        end
        object pmTlFxNotchFilter: TMenuItem
          Tag = 29
          Caption = 'Notch Filter'
          OnClick = TlFxMenuClick
        end
        object pmTlFxPhaser: TMenuItem
          Tag = 5
          Caption = 'Phaser'
          OnClick = TlFxMenuClick
        end
        object pmTlFxPingPongDelay: TMenuItem
          Tag = 20
          Caption = 'Ping-Pong Delay'
          OnClick = TlFxMenuClick
        end
        object pmTlFxPitchShift: TMenuItem
          Tag = 30
          Caption = 'Pitch Shift'
          OnClick = TlFxMenuClick
        end
        object pmTlFxPresenceBoost: TMenuItem
          Tag = 31
          Caption = 'Presence Boost'
          OnClick = TlFxMenuClick
        end
        object pmTlFxReverb: TMenuItem
          Tag = 2
          Caption = 'Reverb'
          OnClick = TlFxMenuClick
        end
        object pmTlUndoEffect: TMenuItem
          Caption = 'Undo Effect'
          OnClick = TlUndoEffectClick
        end
        object pmTlReverseRange: TMenuItem
          Caption = 'Reverse'
          OnClick = btnTlReverseRangeClick
        end
        object pmTlFxSaturation: TMenuItem
          Tag = 8
          Caption = 'Saturation'
          OnClick = TlFxMenuClick
        end
        object pmTlFxSilence: TMenuItem
          Tag = 11
          Caption = 'Silence'
          OnClick = TlFxMenuClick
        end
        object pmTlFxStereoWidener: TMenuItem
          Tag = 32
          Caption = 'Stereo Widener'
          OnClick = TlFxMenuClick
        end
        object pmTlFxTransientShaper: TMenuItem
          Tag = 33
          Caption = 'Transient Shaper'
          OnClick = TlFxMenuClick
        end
        object pmTlFxTrebleBoost: TMenuItem
          Tag = 34
          Caption = 'Treble Boost'
          OnClick = TlFxMenuClick
        end
        object pmTlFxTremolo: TMenuItem
          Tag = 6
          Caption = 'Tremolo'
          OnClick = TlFxMenuClick
        end
      end
      object pmTlSepEditE: TMenuItem
        Caption = '-'
      end
      object pmTlSaveSelWav: TMenuItem
        Tag = 1
        Caption = 'Save Selection as WAV...'
        OnClick = TlSaveSelectionClick
      end
      object pmTlSaveSelPcm: TMenuItem
        Tag = 5
        Caption = 'Save Selection as PCM...'
        OnClick = TlSaveSelectionClick
      end
      object pmTlSaveSelFlac: TMenuItem
        Tag = 6
        Caption = 'Save Selection as FLAC...'
        OnClick = TlSaveSelectionClick
      end
    end
  end
  object pmTimelineRuler: TPopupMenu
    OnPopup = pmTimelineRulerPopup
    Left = 216
    Top = 56
    object pmTimelineRulerShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmTlrAddMarker: TMenuItem
      Caption = 'Add Marker Here...'
      OnClick = btnTlAddMarkerHereClick
    end
    object pmTlrLoop: TMenuItem
      Caption = 'Loop'
      object pmTlrLoopStart: TMenuItem
        Caption = 'Set Loop Start Here'
        OnClick = btnTlLoopStartClick
      end
      object pmTlrLoopEnd: TMenuItem
        Caption = 'Set Loop End Here'
        OnClick = btnTlLoopEndClick
      end
      object pmTlrLoopEnabled: TMenuItem
        Caption = 'Loop Playback'
        OnClick = btnTlLoopToggleClick
      end
      object pmTlrLoopSep1: TMenuItem
        Caption = '-'
      end
      object pmTlrLoopToRange: TMenuItem
        Caption = 'Set Loop to Selection'
        OnClick = btnTlLoopToRangeClick
      end
    end
    object pmTlrSepRange: TMenuItem
      Caption = '-'
    end
    object pmTlrSplitRange: TMenuItem
      Caption = 'Split Clips at Range Edges'
      OnClick = btnTlSplitRangeClick
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
    object pmTlrSep1: TMenuItem
      Caption = '-'
    end
    object pmTlrGoStart: TMenuItem
      Caption = 'Go to Start'
      OnClick = btnTlGoStartClick
    end
    object pmTlrGoEnd: TMenuItem
      Caption = 'Go to End'
      OnClick = btnTlGoEndClick
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
    object pmTlrUndo: TMenuItem
      Caption = 'Undo'
      OnClick = btnTlUndoClick
    end
    object pmTlrRedo: TMenuItem
      Caption = 'Redo'
      OnClick = btnTlRedoClick
    end
    object pmTlrHistory: TMenuItem
      Caption = 'Undo/Redo History'
    end
    object pmTimelineRulerExportSep: TMenuItem
      Caption = '-'
    end
    object pmTimelineRulerExport: TMenuItem
      Caption = 'Export'
      object pmTimelineRulerExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmTimelineRulerExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmTimelineRulerExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmTimelineRulerExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
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
      object pmSystemExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object pmLog: TPopupMenu
    Left = 376
    Top = 16
    object pmLogShowLog: TMenuItem
      Caption = 'Open Log...'
      OnClick = ShowLogClick
    end
    object pmApplyLevel: TMenuItem
      Caption = 'Apply level'
      OnClick = btnApplyLevelClick
    end
    object pmLogSep1: TMenuItem
      Caption = '-'
    end
    object pmClearLogView: TMenuItem
      Caption = 'Clear view'
      OnClick = btnClearLogViewClick
    end
    object pmLogExportSep: TMenuItem
      Caption = '-'
    end
    object pmLogExport: TMenuItem
      Caption = 'Export'
      object pmLogExportWav: TMenuItem
        Caption = 'WAV...'
        OnClick = pmTlExportWavClick
      end
      object pmLogExportMp3: TMenuItem
        Caption = 'MP3...'
        OnClick = pmTlExportMp3Click
      end
      object pmLogExportMp4: TMenuItem
        Caption = 'MP4...'
        OnClick = pmTlExportMp4Click
      end
      object pmLogExportFlac: TMenuItem
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
      object pmAiExportFlac: TMenuItem
        Caption = 'FLAC...'
        OnClick = pmTlExportFlacClick
      end
    end
  end
  object dlgRecSaved: TOpenDialog
    Filter = 'Audio files|*.wav;*.flac;*.mp3;*.mp4;*.m4a|All files|*.*'
    Options = [ofFileMustExist, ofEnableSizing]
    Title = 'Add full saved audio to timeline'
    Left = 880
    Top = 640
  end
  object dlgRecSaveTake: TSaveDialog
    DefaultExt = 'wav'
    Filter = 'WAV audio (*.wav)|*.wav|All files (*.*)|*.*'
    Options = [ofOverwritePrompt, ofPathMustExist, ofEnableSizing]
    Title = 'Save selected take as'
    Left = 880
    Top = 688
  end
end
