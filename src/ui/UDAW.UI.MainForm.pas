unit UDAW.UI.MainForm;
{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

{ Phase 1 diagnostics / control panel.

  Every control on this window is placed at DESIGN TIME (see the .dfm for the
  Delphi/VCL build and the .lfm for the Lazarus/LCL build). Nothing here creates
  ordinary interface controls at run time - per the project's non-negotiable
  rule, forms stay fully editable in the visual designer.

  The window is a live view onto the core platform framework: platform + path
  info, the async logger, the background job manager, and OS secure storage. }

interface

uses
  {$IFDEF FPC}
  LCLIntf, LCLType,
  {$ELSE}
  Winapi.ShellAPI, Winapi.Windows, Winapi.Messages,
  System.Types, System.UITypes,   // lets Point / MessageDlg inline-expand
  FileCtrl,                       // SelectDirectory, for the Settings tab
  UDAW.UI.HelpForm,               // embedded-browser Help Centre window
  UDAW.Web.HelpClient,            // TaurusTLS/Indy fetch for the Help Centre
  UDAW.Licensing,                 // online registration (Settings > Registration)
  UDAW.Update,                    // online version/checksum check + self-update
  UDAW.Input.KeyHooks,            // Ctrl+Pause/Ctrl+Space global hotkeys
  {$ENDIF}
  UDAW.UI.AboutForm, UDAW.UI.LogForm, UDAW.UI.BrowserWindow,
  SysUtils, Classes, Math, Graphics, Controls, Forms, Dialogs, StdCtrls, ComCtrls,
  ExtCtrls, StrUtils, Menus,
  UDAW.App, UDAW.Types, UDAW.Errors, UDAW.Logging, UDAW.Jobs, UDAW.SecureStorage,
  UDAW.AI.HTTP,
  UDAW.Config, UDAW.Paths, UDAW.UI.Theme, UDAW.Version,
  UDAW.Audio.Engine, UDAW.Audio.Device, UDAW.Audio.Source, UDAW.Audio.Offline, UDAW.Audio.Buffer,
  UDAW.Audio.Types,
  UDAW.DSP.Math, UDAW.DSP.Filters, UDAW.DSP.FFT, UDAW.DSP.Meter,
  UDAW.Audio.Graph, UDAW.Audio.Graph.Nodes,
  UDAW.Project.Document, UDAW.Project.Serialization, UDAW.Project.Commands,
  UDAW.Project.Recovery, UDAW.Project.WindowLayout, Generics.Collections,
  UDAW.Codec.WAV, UDAW.Codec.ProTracker, UDAW.Codec.XM, UDAW.Codec.MPTM,
  UDAW.Codec.MP3.Frame, UDAW.Codec.MP3.Decoder, UDAW.Codec.MP3.Encoder,
  UDAW.Codec.MP3.Metadata, UDAW.Codec.MP3,
  UDAW.Codec.MP3.Source, UDAW.Codec.MP3.Timeline,
  UDAW.Codec.FLAC, UDAW.Codec.FLAC.Timeline,
  UDAW.Codec.Ableton, UDAW.Codec.Ableton.Timeline,
  UDAW.Codec.FLStudio, UDAW.Codec.FLStudio.Timeline,
  UDAW.Codec.MP4.Atoms, UDAW.Codec.MP4.Container, UDAW.Codec.MP4,
  UDAW.Codec.MP4.Source, UDAW.Codec.MP4.Timeline,
  UDAW.MIDI.Types, UDAW.MIDI.SMF, UDAW.MIDI.Sequence, UDAW.MIDI.PianoRoll,
  UDAW.MIDI.Engine, UDAW.MIDI.Serialization, UDAW.MIDI.Commands,
  UDAW.MIDI.Hardware, UDAW.MIDI.Capture,
  UDAW.Timeline.Time, UDAW.Timeline.Model, UDAW.Timeline.Serialization,
  UDAW.Timeline.Commands, UDAW.Timeline.View, UDAW.Timeline.Waveform,
  UDAW.Timeline.Playback, UDAW.Timeline.Export, UDAW.Media.Progress,
  UDAW.Media.Attribution,
  UDAW.Mixer.Model, UDAW.Mixer.Serialization, UDAW.Mixer.Engine, UDAW.Mixer.Commands,
  UDAW.Mixer.Automation, UDAW.Mixer.VST2, UDAW.Mixer.CLAP, UDAW.Mixer.VST3,
  UDAW.Mixer.Modulation, UDAW.Timeline.SpectralFx, UDAW.DSP.AudioToMidi,
  UDAW.Sequencer.Patterns, UDAW.Timeline.Warp, UDAW.UI.VST2Editor,
  UDAW.UI.MixInsertParams, System.NetEncoding,
  UDAW.Tracker.Types, UDAW.Tracker.Instrument, UDAW.Tracker.Pattern,
  UDAW.Tracker.Player, UDAW.Tracker.Commands,
  UDAW.Recording.Types, UDAW.Recording.Engine, UDAW.Recording.Takes,
  UDAW.Recording.Recovery, UDAW.Recording.Commands,
  UDAW.Recording.Writer, UDAW.Audio.Ring,
  UDAW.DSP.Visualization, UDAW.DSP.MultibandComp, UDAW.DSP.Mastering,
  UDAW.DSP.TimeStretch, UDAW.DSP.PitchShift, UDAW.DSP.TempoDetect,
  UDAW.AI.Credentials, UDAW.AI.SecureLog, UDAW.AI.MCP,
  UDAW.AI.MCPBridge, UDAW.AI.MCPServer, UDAW.AI.MCPDiag,
  UDAW.AI.Types, UDAW.AI.Providers, UDAW.AI.Suno, UDAW.AI.Luma, UDAW.AI.MusicTab,
  UDAW.AI.ToolCommands, UDAW.AI.Mixing, UDAW.AI.Mastering,
  UDAW.DSP.Analysis, UDAW.UI.ThemeColors, UDAW.UI.Hints,
  UDAW.Voice.Command, UDAW.Voice.Capture, UDAW.Voice.Recognition;

const
  { [ui] - persisted main-window geometry (Settings has no tab for this; it's
    saved automatically on every resize and restored at startup). }
  CFG_SEC_UI        = 'ui';
  CFG_UI_WIDTH      = 'window_width';
  CFG_UI_HEIGHT     = 'window_height';
  CFG_UI_MAXIMIZED  = 'window_maximized';
  CFG_UI_MIXER_STRIP_WIDTH = 'mixer_strip_width';  // FMixZoomFactor, persisted across sessions

  { tmrUI.Interval: 500ms is fine for the log/jobs/meters polling it normally
    drives, but that's far too coarse for the Tracker tab's live row/pattern
    readout and pattern-grid highlight while the transport is running - it
    reads as a choppy jump every half second instead of a moving playhead.
    btnTrkPlayClick/btnTrkStopClick swap the timer to/from this faster rate
    for the duration of tracker playback only. }
  TRK_UI_IDLE_INTERVAL_MS = 500;
  TRK_UI_PLAY_INTERVAL_MS = 33;   // ~30 fps

type
  { TPaintBox (TGraphicControl) does not publish OnMouseWheel, so the DFM/LFM
    streamer raises EReadError on pbTimeline's OnMouseWheel binding at
    startup. This subclass republishes the (already-implemented) property so
    it can be set at design time / streamed from the form resource. }
  TWheelPaintBox = class(TPaintBox)
  published
    property OnMouseWheel;
  end;

  { What a pbMixer mouse-down/drag is currently doing - see
    pbMixerMouseDown/MouseMove/MouseUp. }
  TMixDragMode = (mdmNone, mdmFader, mdmPan, mdmReorderStrip, mdmReorderInsert);

  TfrmMain = class(TForm)
    mnuMain: TMainMenu;
    pnlTop: TPanel;
    lblHeader: TLabel;
    pgc: TPageControl;
    tabSystem: TTabSheet;
    memSystem: TMemo;
    pnlLogView: TPanel;
    lvLog: TListView;
    pnlLogButtons: TPanel;
    cboLevel: TComboBox;
    tabJobs: TTabSheet;
    lvJobs: TListView;
    tabAudio: TTabSheet;
    pnlAudioMeters: TPanel;
    lblOutL: TLabel;
    lblOutR: TLabel;
    lblAudioState: TLabel;
    pbOutL: TProgressBar;
    pbOutR: TProgressBar;
    memAudio: TMemo;
    tabDSP: TTabSheet;
    pnlDspTop: TPanel;
    lblDspSignal: TLabel;
    cboDspSignal: TComboBox;
    lblDspFilter: TLabel;
    cboDspFilter: TComboBox;
    lblDspWindow: TLabel;
    cboDspWindow: TComboBox;
    chkDspLive: TCheckBox;
    pnlDspReadout: TPanel;
    memDspReadout: TMemo;
    pbSpectrum: TPaintBox;
    tabGraph: TTabSheet;
    pnlGraphTop: TPanel;
    lblGraphPreset: TLabel;
    cboGraphPreset: TComboBox;
    chkGraphLive: TCheckBox;
    pnlGraphReadout: TPanel;
    memGraph: TMemo;
    pbGraph: TPaintBox;
    mnuSystem: TMenuItem;
    mnuSystemRefresh: TMenuItem;
    mnuSystemOpenConfigDir: TMenuItem;
    mnuSystemOpenLogDir: TMenuItem;
    mnuLog: TMenuItem;
    mnuApplyLevel: TMenuItem;
    mnuEmitInfo: TMenuItem;
    mnuEmitWarn: TMenuItem;
    mnuEmitError: TMenuItem;
    mnuLogSep1: TMenuItem;
    mnuClearLogView: TMenuItem;
    mnuJobs: TMenuItem;
    mnuRunSelfTest: TMenuItem;
    mnuCancelJobs: TMenuItem;
    mnuAudio: TMenuItem;
    mnuAudioStart: TMenuItem;
    mnuAudioStop: TMenuItem;
    mnuAudioSep1: TMenuItem;
    mnuAudioTone: TMenuItem;
    mnuAudioReset: TMenuItem;
    mnuAudioReopen: TMenuItem;
    mnuDsp: TMenuItem;
    mnuDspAnalyze: TMenuItem;
    mnuGraph: TMenuItem;
    mnuGraphBuild: TMenuItem;
    mnuGraphPlay: TMenuItem;
    pmSystem: TPopupMenu;
    pmSystemRefresh: TMenuItem;
    pmSystemOpenConfigDir: TMenuItem;
    pmSystemOpenLogDir: TMenuItem;
    pmLog: TPopupMenu;
    pmApplyLevel: TMenuItem;
    pmEmitInfo: TMenuItem;
    pmEmitWarn: TMenuItem;
    pmEmitError: TMenuItem;
    pmLogSep1: TMenuItem;
    pmClearLogView: TMenuItem;
    pmJobs: TPopupMenu;
    pmRunSelfTest: TMenuItem;
    pmCancelJobs: TMenuItem;
    pmAudio: TPopupMenu;
    pmAudioStart: TMenuItem;
    pmAudioStop: TMenuItem;
    pmAudioSep1: TMenuItem;
    pmAudioTone: TMenuItem;
    pmAudioReset: TMenuItem;
    pmAudioReopen: TMenuItem;
    pmDsp: TPopupMenu;
    pmDspAnalyze: TMenuItem;
    pmGraph: TPopupMenu;
    pmGraphBuild: TMenuItem;
    pmGraphPlay: TMenuItem;
    tabProject: TTabSheet;
    pnlProjectTop: TPanel;
    lblProjectFile: TLabel;
    lblProjectName: TLabel;
    lblProjectAuthor: TLabel;
    lblProjectTempo: TLabel;
    lblProjectTimeSig: TLabel;
    lblTimeSigSlash: TLabel;
    lblProjectSampleRate: TLabel;
    lblProjectChannels: TLabel;
    lblAutosave: TLabel;
    edtProjectName: TEdit;
    edtProjectAuthor: TEdit;
    edtProjectTempo: TEdit;
    edtTimeSigNum: TEdit;
    edtTimeSigDen: TEdit;
    cboProjectSampleRate: TComboBox;
    edtProjectChannels: TEdit;
    cboAutosaveInterval: TComboBox;
    pnlProjectReadout: TPanel;
    memProject: TMemo;
    mnuProject: TMenuItem;
    mnuProjectFile: TMenuItem;
    mnuProjectNew: TMenuItem;
    mnuProjectOpen: TMenuItem;
    mnuProjectSave: TMenuItem;
    mnuProjectSaveAs: TMenuItem;
    mnuProjectMetadata: TMenuItem;
    mnuProjectApply: TMenuItem;
    mnuProjectEdit: TMenuItem;
    mnuProjectUndo: TMenuItem;
    mnuProjectRedo: TMenuItem;
    mnuProjectGraph: TMenuItem;
    mnuProjectAddGainNode: TMenuItem;
    mnuProjectRemoveLastNode: TMenuItem;
    mnuProjectAutosave: TMenuItem;
    mnuProjectAutosaveNow: TMenuItem;
    mnuProjectRecover: TMenuItem;
    mnuProjectRecent: TMenuItem;
    mnuProjectSepOpen: TMenuItem;
    mnuProjectSepRecent: TMenuItem;
    pmProject: TPopupMenu;
    pmProjectNew: TMenuItem;
    pmProjectOpen: TMenuItem;
    pmProjectSave: TMenuItem;
    pmProjectSaveAs: TMenuItem;
    pmProjectSep1: TMenuItem;
    pmProjectApply: TMenuItem;
    pmProjectSep2: TMenuItem;
    pmProjectUndo: TMenuItem;
    pmProjectRedo: TMenuItem;
    pmProjectSep3: TMenuItem;
    pmProjectAddGainNode: TMenuItem;
    pmProjectRemoveLastNode: TMenuItem;
    pmProjectSep4: TMenuItem;
    pmProjectAutosaveNow: TMenuItem;
    pmProjectRecover: TMenuItem;
    dlgSaveProject: TSaveDialog;
    dlgOpenProject: TOpenDialog;
    tabWav: TTabSheet;
    pnlWavTop: TPanel;
    lblWavFormat: TLabel;
    chkWavLoop: TCheckBox;
    cboWavFormat: TComboBox;
    memWav: TMemo;
    mnuWav: TMenuItem;
    mnuWavImport: TMenuItem;
    mnuWavPlay: TMenuItem;
    mnuWavSep1: TMenuItem;
    mnuWavExportTone: TMenuItem;
    mnuWavRoundTrip: TMenuItem;
    pmWav: TPopupMenu;
    pmWavImport: TMenuItem;
    pmWavPlay: TMenuItem;
    pmWavSep1: TMenuItem;
    pmWavExportTone: TMenuItem;
    pmWavRoundTrip: TMenuItem;
    dlgOpenWav: TOpenDialog;
    dlgSaveWav: TSaveDialog;
    tabMP3: TTabSheet;
    pnlMp3Top: TPanel;
    lblMp3Bitrate: TLabel;
    cboMp3Bitrate: TComboBox;
    memMp3: TMemo;
    mnuMp3: TMenuItem;
    mnuMp3Import: TMenuItem;
    mnuMp3ReadTags: TMenuItem;
    mnuMp3ToTimeline: TMenuItem;
    mnuMp3Sep1: TMenuItem;
    mnuMp3ExportTone: TMenuItem;
    mnuMp3RoundTrip: TMenuItem;
    mnuMp3Sep2: TMenuItem;
    mnuMp3Play: TMenuItem;
    mnuMp3Stop: TMenuItem;
    pmMp3: TPopupMenu;
    pmMp3Import: TMenuItem;
    pmMp3ReadTags: TMenuItem;
    pmMp3ToTimeline: TMenuItem;
    pmMp3Sep1: TMenuItem;
    pmMp3ExportTone: TMenuItem;
    pmMp3RoundTrip: TMenuItem;
    pmMp3Sep2: TMenuItem;
    pmMp3Play: TMenuItem;
    pmMp3Stop: TMenuItem;
    dlgOpenMp3: TOpenDialog;
    dlgSaveMp3: TSaveDialog;
    tabMP4: TTabSheet;
    pnlMp4Top: TPanel;
    lblMp4Fmt: TLabel;
    cboMp4Fmt: TComboBox;
    memMp4: TMemo;
    mnuMp4: TMenuItem;
    mnuMp4Probe: TMenuItem;
    mnuMp4Import: TMenuItem;
    mnuMp4Sep1: TMenuItem;
    mnuMp4ExportTone: TMenuItem;
    mnuMp4RoundTrip: TMenuItem;
    mnuMp4ToTimeline: TMenuItem;
    mnuMp4Sep2: TMenuItem;
    mnuMp4Play: TMenuItem;
    mnuMp4Stop: TMenuItem;
    mnuHelpAboutUdawSep: TMenuItem;
    mnuHelpAboutUdaw: TMenuItem;
    pmMp4: TPopupMenu;
    pmMp4Probe: TMenuItem;
    pmMp4Import: TMenuItem;
    pmMp4Sep1: TMenuItem;
    pmMp4ExportTone: TMenuItem;
    pmMp4RoundTrip: TMenuItem;
    pmMp4ToTimeline: TMenuItem;
    pmMp4Sep2: TMenuItem;
    pmMp4Play: TMenuItem;
    pmMp4Stop: TMenuItem;
    tabMIDI: TTabSheet;
    pnlMidiTop: TPanel;
    lblMidiClip: TLabel;
    lblMidiNote: TLabel;
    lblMidiGrid: TLabel;
    cboMidiClip: TComboBox;
    edtMidiNote: TEdit;
    edtMidiStart: TEdit;
    edtMidiLen: TEdit;
    edtMidiVel: TEdit;
    cboMidiGrid: TComboBox;
    lblMidiScale: TLabel;
    cboMidiScaleRoot: TComboBox;
    cboMidiScaleType: TComboBox;
    chkMidiScaleHighlight: TCheckBox;
    pbPianoRoll: TPaintBox;
    memMidi: TMemo;
    mnuMidi: TMenuItem;
    mnuMidiClip: TMenuItem;
    mnuMidiAddClip: TMenuItem;
    mnuMidiAddTrack: TMenuItem;
    mnuMidiNote: TMenuItem;
    mnuMidiAddNote: TMenuItem;
    mnuMidiDelNote: TMenuItem;
    mnuMidiGrid: TMenuItem;
    mnuMidiQuantize: TMenuItem;
    mnuMidiHumanize: TMenuItem;
    mnuMidiDemo: TMenuItem;
    mnuMidiTransport: TMenuItem;
    mnuMidiPlay: TMenuItem;
    mnuMidiStop: TMenuItem;
    mnuMidiTransportSep: TMenuItem;
    mnuMidiRecord: TMenuItem;
    mnuMidiPanic: TMenuItem;
    mnuMidiEdit: TMenuItem;
    mnuMidiUndo: TMenuItem;
    mnuMidiRedo: TMenuItem;
    mnuMidiImport: TMenuItem;
    mnuMidiExport: TMenuItem;
    pmPianoRoll: TPopupMenu;
    pmMidiAddNote: TMenuItem;
    pmMidiDelNote: TMenuItem;
    pmMidiQuantize: TMenuItem;
    pmMidiHumanize: TMenuItem;
    pmMidiDemo: TMenuItem;
    pmMidiSep1: TMenuItem;
    pmMidiUndo: TMenuItem;
    pmMidiRedo: TMenuItem;
    pmMidiSep2: TMenuItem;
    pmMidiPlay: TMenuItem;
    pmMidiStop: TMenuItem;
    dlgOpenMp4: TOpenDialog;
    dlgSaveMp4: TSaveDialog;
    dlgOpenMidi: TOpenDialog;
    dlgSaveMidi: TSaveDialog;
    tabSettings: TTabSheet;
    pgcSettings, pgcDiagnostics: TPageControl;
    tabSettingsGeneral, tabSettingsDiagnostics: TTabSheet;
    tabRegistration: TTabSheet;
    grpRegStatus, grpRegCredentials, grpRegUpdate: TGroupBox;
    lblRegStatus, lblRegDetail, lblRegUsername, lblRegPassword, lblRegSerial,
      lblRegHint, lblRegVersion, lblRegUpdateStatus: TLabel;
    edtRegUsername, edtRegPassword, edtRegSerial: TEdit;
    btnRegRegister, btnRegUnregister, btnRegCheckUpdate, btnRegInstallUpdate: TButton;
    lblSettingsStatus: TLabel;
    sbSettings: TScrollBox;
    mnuSettings: TMenuItem;
    mnuSettingsSave: TMenuItem;
    mnuSettingsReload: TMenuItem;
    pmSettings: TPopupMenu;
    pmSettingsSave: TMenuItem;
    pmSettingsReload: TMenuItem;
    grpStartup: TGroupBox;
    lblSetBackend: TLabel;
    cboSetBackend: TComboBox;
    lblSetRate: TLabel;
    cboSetRate: TComboBox;
    lblSetBuffer: TLabel;
    cboSetBuffer: TComboBox;
    lblSetOutCh: TLabel;
    edSetOutCh: TEdit;
    lblSetInCh: TLabel;
    edSetInCh: TEdit;
    lblSetInDevice: TLabel;
    cboSetInDevice: TComboBox;
    chkSetAutostart: TCheckBox;
    chkSetCapture: TCheckBox;
    chkSetExclusive: TCheckBox;
    chkSetTempoAuto: TCheckBox;
    chkSetTempoResample: TCheckBox;
    chkSetHints: TCheckBox;
    lblSetLogLevel: TLabel;
    cboSetLogLevel: TComboBox;
    lblSetLocale: TLabel;
    edSetLocale: TEdit;
    lblSetTheme: TLabel;
    cboSetTheme: TComboBox;
    lblThemeInfo: TLabel;
    grpDirs: TGroupBox;
    lblDirProjects: TLabel;
    edDirProjects: TEdit;
    btnDirProjects: TButton;
    lblDirAudioLib: TLabel;
    edDirAudioLib: TEdit;
    btnDirAudioLib: TButton;
    lblDirSfx: TLabel;
    edDirSfx: TEdit;
    btnDirSfx: TButton;
    lblDirExport: TLabel;
    edDirExport: TEdit;
    btnDirExport: TButton;
    lblDirRecordings: TLabel;
    edDirRecordings: TEdit;
    btnDirRecordings: TButton;
    lblDirTemp, lblDirCache: TLabel;
    edDirTemp, edDirCache: TEdit;
    btnDirTemp, btnDirCache: TButton;
    grpSystemPaths: TGroupBox;
    memSysPaths: TMemo;
    grpColorTheme: TGroupBox;
    lblColorTheme: TLabel;
    cboColorTheme: TComboBox;
    btnColorThemeSave: TButton;
    btnColorThemeReset: TButton;
    btnColorThemeExport: TButton;
    btnColorThemeImport: TButton;
    lblColorThemeStatus: TLabel;
    grpMidiDevices: TGroupBox;
    lblSetMidiIn: TLabel;
    lblSetMidiOut: TLabel;
    cboSetMidiInDevice: TComboBox;
    cboSetMidiOutDevice: TComboBox;
    btnSetMidiRefresh: TButton;
    btnSetMidiPanic: TButton;
    lblSetMidiStatus: TLabel;
    tabColors: TTabSheet;
    lblFadeDisplay: TLabel;
    cboFadeDisplay: TComboBox;
    tabKeyHooks: TTabSheet;
    lvKeyHooks: TListView;
    lblKeyHooksHint: TLabel;
    pnlColorsTop: TPanel;
    lblColorsTitle: TLabel;
    lbColorSwatches: TListBox;
    pbColorPreview: TPaintBox;
    btnColorPick: TButton;
    btnColorsSave: TButton;
    btnColorsResetTheme: TButton;
    lblColorsStatus: TLabel;
    lblColorsHint: TLabel;
    tabTimeline: TTabSheet;
    pnlTimelineTop: TPanel;
    lblTlTempo: TLabel;
    edtTlTempo: TEdit;
    chkTlMetronome: TCheckBox;
    lblTlSnap: TLabel;
    lblTlPos: TLabel;
    lblTlPosCaption: TLabel;
    lblTlMasterCaption: TLabel;
    bvlTlSep1: TBevel;
    bvlTlSep2: TBevel;
    bvlTlSep3: TBevel;
    cboTlSnap: TComboBox;
    lblTlMasterVol: TLabel;
    tbTlMasterVol: TTrackBar;
    mnuTimeline: TMenuItem;
    mnuTlExport, pmTlExport: TMenuItem;
    dlgTimelineExport: TSaveDialog;
    mnuTlBuild: TMenuItem;
    mnuTlDemo: TMenuItem;
    mnuTlAddTrack: TMenuItem;
    mnuTlRemoveTrack: TMenuItem;
    mnuTlClip: TMenuItem;
    mnuTlAddClip: TMenuItem;
    mnuTlSplit: TMenuItem;
    mnuTlDeleteClip: TMenuItem;
    mnuTlImport: TMenuItem;
    mnuTlImportWav: TMenuItem;
    mnuTlImportMp3: TMenuItem;
    mnuTlImportMp4: TMenuItem;
    mnuTlImportFlac: TMenuItem;
    mnuTlImportSep1: TMenuItem;
    mnuTlImportMod: TMenuItem;
    mnuTlImportXm: TMenuItem;
    mnuTlImportMptm: TMenuItem;
    mnuTlImportSep2: TMenuItem;
    mnuTlImportAls: TMenuItem;
    mnuTlImportFlp: TMenuItem;
    mnuTlNavigation: TMenuItem;
    mnuTlZoomIn: TMenuItem;
    mnuTlZoomOut: TMenuItem;
    mnuTlTransport: TMenuItem;
    mnuTlPlay: TMenuItem;
    mnuTlPlayFromBeginning: TMenuItem;
    mnuTlPlayFromCurrent: TMenuItem;
    mnuTlPlayReverse: TMenuItem;
    mnuTlPlayPingPong: TMenuItem;
    mnuTlStop: TMenuItem;
    mnuTlEdit: TMenuItem;
    mnuTlUndo: TMenuItem;
    mnuTlRedo: TMenuItem;
    mnuTlEditSep1: TMenuItem;
    mnuTlCut: TMenuItem;
    mnuTlCopy: TMenuItem;
    mnuTlPaste: TMenuItem;
    mnuTlEditSep3: TMenuItem;
    mnuTlNormalizeRange: TMenuItem;
    mnuTlReverseRange: TMenuItem;
    mnuTlClipTempo: TMenuItem;
    mnuTlWarp, mnuTlWarpAdd, mnuTlWarpSnap, mnuTlWarpAuto, mnuTlWarpApply, mnuTlWarpClear,
    pmTlWarp, pmTlWarpAdd, pmTlWarpSnap, pmTlWarpAuto, pmTlWarpApply, pmTlWarpClear: TMenuItem;
    pmTlClipTempo: TMenuItem;
    mnuTlEditSep4: TMenuItem;
    mnuTlEffects: TMenuItem;
    mnuTlFxFadeIn, mnuTlFxFadeOut, pmTlFxFadeIn, pmTlFxFadeOut: TMenuItem;
    mnuTlFxBalance, mnuTlFxBassEnhance, mnuTlFxDCOffsetRemover, mnuTlFxExciter, mnuTlFxHighPassFilter, mnuTlFxLowPassFilter, mnuTlFxMakeMono, mnuTlFxMultibandCompressor, mnuTlFxNotchFilter, mnuTlFxPitchShift, mnuTlFxPresenceBoost, mnuTlFxStereoWidener, mnuTlFxTransientShaper, mnuTlFxTrebleBoost, pmTlFxBalance, pmTlFxBassEnhance, pmTlFxDCOffsetRemover, pmTlFxExciter, pmTlFxHighPassFilter, pmTlFxLowPassFilter, pmTlFxMakeMono, pmTlFxMultibandCompressor, pmTlFxNotchFilter, pmTlFxPitchShift, pmTlFxPresenceBoost, pmTlFxStereoWidener, pmTlFxTransientShaper, pmTlFxTrebleBoost: TMenuItem;
    mnuTlFxAmplify, mnuTlFxDeEsser, mnuTlFxDelay, mnuTlFxExpander, mnuTlFxFoldback, mnuTlFxGate, mnuTlFxHardClip, mnuTlFxLimiter, mnuTlFxPingPongDelay, pmTlFxAmplify, pmTlFxDeEsser, pmTlFxDelay, pmTlFxExpander, pmTlFxFoldback, pmTlFxGate, pmTlFxHardClip, pmTlFxLimiter, pmTlFxPingPongDelay: TMenuItem;
    mnuTlFxNoiseReduction, mnuTlFxAutoTune, mnuTlFxConvolutionReverb, mnuTlFxSplitStems, mnuTlFxAudioToMidi, pmTlFxNoiseReduction, pmTlFxAutoTune, pmTlFxConvolutionReverb, pmTlFxSplitStems, pmTlFxAudioToMidi: TMenuItem;
    mnuTlFxCompressor: TMenuItem;
    mnuTlFxReverb: TMenuItem;
    mnuTlFxChorus: TMenuItem;
    mnuTlFxFlanger: TMenuItem;
    mnuTlFxPhaser: TMenuItem;
    mnuTlFxTremolo: TMenuItem;
    mnuTlFxAutoPan: TMenuItem;
    mnuTlFxSaturation: TMenuItem;
    mnuTlFxBitCrusher: TMenuItem;
    mnuTlFxBrightenEQ: TMenuItem;
    mnuTlFxSilence: TMenuItem;
    mnuTlEditSep2: TMenuItem;
    mnuTlRenameTrack: TMenuItem;
    mnuTlEditSep5: TMenuItem;
    mnuTlSaveSelWav: TMenuItem;
    mnuTlSaveSelPcm: TMenuItem;
    mnuTlSaveSelFlac: TMenuItem;
    pmTlSepEditE: TMenuItem;
    pmTlSaveSelWav: TMenuItem;
    pmTlSaveSelPcm: TMenuItem;
    pmTlSaveSelFlac: TMenuItem;
    mnuTlTrack: TMenuItem;
    mnuTlTrackUp: TMenuItem;
    mnuTlTrackDown: TMenuItem;
    mnuTlMuteTrack: TMenuItem;
    mnuTlLoop: TMenuItem;
    mnuTlLoopStart: TMenuItem;
    mnuTlLoopEnd: TMenuItem;
    mnuTlLoopSep1: TMenuItem;
    mnuTlLoopToggle: TMenuItem;
    mnuTlLoopSep2: TMenuItem;
    mnuTlLoopToRange: TMenuItem;
    mnuTlNavNext: TMenuItem;
    mnuTlNavPrev: TMenuItem;
    mnuTlJumpElementStart: TMenuItem;
    mnuTlJumpElementEnd: TMenuItem;
    mnuTlExportWav: TMenuItem;
    mnuTlExportMp3: TMenuItem;
    mnuTlExportMp4: TMenuItem;
    mnuTlExportFlac: TMenuItem;
    mnuTlExportSep: TMenuItem;
    pmTimeline: TPopupMenu;
    pmTlAddClip: TMenuItem;
    pmTlSplit: TMenuItem;
    pmTlDeleteClip: TMenuItem;
    pmTlRemoveTrack: TMenuItem;
    pmTlImport: TMenuItem;
    pmTlImportWav: TMenuItem;
    pmTlImportMp3: TMenuItem;
    pmTlImportMp4: TMenuItem;
    pmTlImportFlac: TMenuItem;
    pmTlImportSep1: TMenuItem;
    pmTlImportMod: TMenuItem;
    pmTlImportXm: TMenuItem;
    pmTlImportMptm: TMenuItem;
    pmTlImportSep2: TMenuItem;
    pmTlImportAls: TMenuItem;
    pmTlImportFlp: TMenuItem;
    pmTlSep1: TMenuItem;
    pmTlNavigation: TMenuItem;
    pmTlZoomIn: TMenuItem;
    pmTlZoomOut: TMenuItem;
    pmTlSep2: TMenuItem;
    pmTlUndo: TMenuItem;
    pmTlRedo: TMenuItem;
    pmTlHistory: TMenuItem;
    pmTlSep3: TMenuItem;
    pmTlPlay: TMenuItem;
    pmTlPlayFromBeginning: TMenuItem;
    pmTlPlayFromCurrent: TMenuItem;
    pmTlPlayReverse: TMenuItem;
    pmTlPlayPingPong: TMenuItem;
    pmTlStop: TMenuItem;
    pmTlSep4: TMenuItem;
    pmTlCut: TMenuItem;
    pmTlCopy: TMenuItem;
    pmTlPaste: TMenuItem;
    pmTlCopySelection: TMenuItem;
    pmTlPasteSelection: TMenuItem;
    pmTlSepEditC: TMenuItem;
    pmTlNormalizeRange: TMenuItem;
    pmTlReverseRange: TMenuItem;
    pmTlSepEditD: TMenuItem;
    pmTlEffects: TMenuItem;
    pmTlFxCompressor: TMenuItem;
    pmTlFxReverb: TMenuItem;
    pmTlFxChorus: TMenuItem;
    pmTlFxFlanger: TMenuItem;
    pmTlFxPhaser: TMenuItem;
    pmTlFxTremolo: TMenuItem;
    pmTlFxAutoPan: TMenuItem;
    pmTlFxSaturation: TMenuItem;
    pmTlFxBitCrusher: TMenuItem;
    pmTlFxBrightenEQ: TMenuItem;
    pmTlFxSilence: TMenuItem;
    pmTlUndoEffect: TMenuItem;
    mnuTlUndoEffect: TMenuItem;
    pmTlSep5: TMenuItem;
    pmTlTrackUp: TMenuItem;
    pmTlTrackDown: TMenuItem;
    pmTlMuteTrack: TMenuItem;
    pmTlTimelineCat: TMenuItem;
    pmTlEditCat: TMenuItem;
    pmTlAddTrack: TMenuItem;
    pmTlRenameTrack: TMenuItem;
    pmTlSep6: TMenuItem;
    pmTlLoop: TMenuItem;
    pmTlLoopStart: TMenuItem;
    pmTlLoopEnd: TMenuItem;
    pmTlLoopToggle: TMenuItem;
    pmTlLoopSep1: TMenuItem;
    pmTlLoopToRange: TMenuItem;
    pmTlSep7: TMenuItem;
    pmTlNavNext: TMenuItem;
    pmTlNavPrev: TMenuItem;
    pmTlSep8: TMenuItem;
    pmTlJumpElementStart: TMenuItem;
    pmTlJumpElementEnd: TMenuItem;
    pmTlExportWav: TMenuItem;
    pmTlExportMp3: TMenuItem;
    pmTlExportMp4: TMenuItem;
    pmTlExportFlac: TMenuItem;
    pmTlExportSep: TMenuItem;
    pmTimelineRuler: TPopupMenu;
    pmTlrAddMarker: TMenuItem;
    pmTlrLoop: TMenuItem;
    pmTlrLoopStart: TMenuItem;
    pmTlrLoopEnd: TMenuItem;
    pmTlrLoopEnabled: TMenuItem;
    pmTlrLoopSep1: TMenuItem;
    pmTlrLoopToRange: TMenuItem;
    pmTlrSepRange: TMenuItem;
    pmTlrSplitRange: TMenuItem;
    pmTlrDeleteRange: TMenuItem;
    pmTlrFadeInRange: TMenuItem;
    pmTlrFadeOutRange: TMenuItem;
    pmTlrSep1: TMenuItem;
    pmTlrGoStart: TMenuItem;
    pmTlrGoEnd: TMenuItem;
    pmTlrSep2: TMenuItem;
    pmTlrZoomIn: TMenuItem;
    pmTlrZoomOut: TMenuItem;
    pmTlrZoomFit: TMenuItem;
    pmTlrSep3: TMenuItem;
    pmTlrPlay: TMenuItem;
    pmTlrStop: TMenuItem;
    pmTlrSep4: TMenuItem;
    pmTlrUndo: TMenuItem;
    pmTlrRedo: TMenuItem;
    pmTlrHistory: TMenuItem;
    pnlTimelineReadout: TPanel;
    memTimeline: TMemo;
    sbTlHorz: TScrollBar;
    sbTlVert: TScrollBar;
    pbTimeline: TWheelPaintBox;
    pbTlMeters: TPaintBox;
    tabRecording: TTabSheet;
    pnlRecTop: TPanel;
    lblRecChannels: TLabel;
    cboRecChannels: TComboBox;
    lblRecFormat: TLabel;
    cboRecFormat: TComboBox;
    lblRecDuration: TLabel;
    edtRecDuration: TEdit;
    lblRecPunch: TLabel;
    cboRecPunch: TComboBox;
    lblRecPunchIn: TLabel;
    edtRecPunchIn: TEdit;
    lblRecPunchOut: TLabel;
    edtRecPunchOut: TEdit;
    lblRecPreRoll: TLabel;
    edtRecPreRoll: TEdit;
    lblRecCountIn: TLabel;
    edtRecCountIn: TEdit;
    chkRecLoop: TCheckBox;
    lblRecLoopStart: TLabel;
    edtRecLoopStart: TEdit;
    lblRecLoopEnd: TLabel;
    edtRecLoopEnd: TEdit;
    chkRecMonitor: TCheckBox;
    btnRecArm: TButton;
    btnRecCommit: TButton;
    btnRecScan: TButton;
    btnRecSaved: TButton;
    btnRecSaveTake: TButton;
    btnRecAddTakeToTimeline: TButton;
    btnRecCommitComp: TButton;
    btnRecResetComp: TButton;
    lblRecDestination: TLabel;
    lblRecMicState: TLabel;
    dlgRecSaved: TOpenDialog;
    dlgRecSaveTake: TSaveDialog;
    pnlRecReadout: TPanel;
    memRec: TMemo;
    pbRecTakes: TPaintBox;
    mnuRecording: TMenuItem;
    mnuRecArm: TMenuItem;
    mnuRecCommit: TMenuItem;
    mnuRecScan: TMenuItem;
    pmRecording: TPopupMenu;
    pmRecArm: TMenuItem;
    pmRecCommit: TMenuItem;
    pmRecScan: TMenuItem;
    tabSecure: TTabSheet;
    lblSecureProvider: TLabel;
    lblKey: TLabel;
    edtKey: TEdit;
    lblValue: TLabel;
    edtValue: TEdit;
    memSecure: TMemo;
    btnSecStore: TButton;
    btnSecRead: TButton;
    btnSecDelete: TButton;
    chkSecReveal: TCheckBox;
    btnSecSeal: TButton;
    btnSecVerify: TButton;
    btnSecProbe: TButton;
    mnuSecure: TMenuItem;
    mnuSecretSet: TMenuItem;
    mnuSecretGet: TMenuItem;
    mnuSecretDelete: TMenuItem;
    pmSecure: TPopupMenu;
    pmSecretSet: TMenuItem;
    pmSecretGet: TMenuItem;
    pmSecretDelete: TMenuItem;
    tabMixer: TTabSheet;
    pnlMixTop: TPanel;
    lblMixStrip: TLabel;
    cboMixStrip: TComboBox;
    lblMixTrackLink: TLabel;
    cboMixTrackLink: TComboBox;
    lblMixFader: TLabel;
    edtMixFader: TEdit;
    lblMixPan: TLabel;
    edtMixPan: TEdit;
    chkMixMute: TCheckBox;
    chkMixSolo: TCheckBox;
    lblMixRoute: TLabel;
    cboMixRoute: TComboBox;
    cboMixInsertKind: TComboBox;
    btnMixAddVST: TButton;
    mnuMixModulation, mnuMixModLFO, mnuMixModRandom, mnuMixModSteps, mnuMixModFollower, mnuMixModMacro, mnuMixModRoute, mnuMixModList, mnuMixModClear: TMenuItem;
    btnMixEditVST: TButton;
    lblMixAutoParam: TLabel;
    cboMixAutoParam: TComboBox;
    cboMixAutoMode: TComboBox;
    lblMixZoom: TLabel;
    tbMixZoom: TTrackBar;
    lblMixMasterLoudness: TLabel;
    lblMixMeterHold: TLabel;
    lblMixMeterDecay: TLabel;
    edtMixMeterHold: TEdit;
    edtMixMeterDecay: TEdit;
    btnMixMeterApply: TButton;
    { on-panel Mixer workflow row: Add/Remove insert, Apply strip, Undo/Redo
      were previously reachable only through the Mixer main menu or the
      pbMixer right-click popup (mnuMix.../pmMix...) - no visible button on
      the strip-editor panel itself did the single most common action (apply
      the chosen insert kind). These reuse those same existing OnClick
      handlers; nothing new was added to the command/mixer layer. }
    btnMixAddInsertRow: TButton;
    btnMixDelInsertRow: TButton;
    btnMixApplyRow: TButton;
    btnMixUndoRow: TButton;
    btnMixRedoRow: TButton;
    pbMixAuto: TPaintBox;
    dlgOpenVst: TOpenDialog;
    pnlMixReadout: TPanel;
    memMix: TMemo;
    pbMixer: TPaintBox;
    mnuMixer: TMenuItem;
    mnuMixStrip: TMenuItem;
    mnuMixAddTrack: TMenuItem;
    mnuMixAddBus: TMenuItem;
    mnuMixAddAux: TMenuItem;
    mnuMixAddVCA: TMenuItem;
    mnuMixRemove: TMenuItem;
    mnuMixApply: TMenuItem;
    mnuMixInsert: TMenuItem;
    mnuMixAddInsert: TMenuItem;
    mnuMixDelInsert: TMenuItem;
    mnuMixEdit: TMenuItem;
    mnuMixUndo: TMenuItem;
    mnuMixRedo: TMenuItem;
    mnuMixTools: TMenuItem;
    mnuMixPreview: TMenuItem;
    pmMixer: TPopupMenu;
    pmMixAddTrack: TMenuItem;
    pmMixAddBus: TMenuItem;
    pmMixAddAux: TMenuItem;
    pmMixAddVCA: TMenuItem;
    pmMixSep1: TMenuItem;
    pmMixRemove: TMenuItem;
    pmMixApply: TMenuItem;
    pmMixSep2: TMenuItem;
    pmMixAddInsert: TMenuItem;
    pmMixDelInsert: TMenuItem;
    pmMixSep3: TMenuItem;
    pmMixUndo: TMenuItem;
    pmMixRedo: TMenuItem;
    pmMixSep4: TMenuItem;
    pmMixPreview: TMenuItem;
    tabTracker: TTabSheet;
    pnlTrkTop: TPanel;
    lblTrkPattern: TLabel;
    cboTrkPattern: TComboBox;
    lblTrkSpeed: TLabel;
    edtTrkSpeed: TEdit;
    lblTrkBPM: TLabel;
    edtTrkBPM: TEdit;
    lblTrkNote: TLabel;
    edtTrkNote: TEdit;
    lblTrkInstr: TLabel;
    edtTrkInstr: TEdit;
    lblTrkVol: TLabel;
    edtTrkVol: TEdit;
    lblTrkEff: TLabel;
    edtTrkEff: TEdit;
    lblTrkParam: TLabel;
    edtTrkParam: TEdit;
    pnlTrkReadout: TPanel;
    memTrk: TMemo;
    pnlTrkSequence: TPanel;
    lblTrkSeq: TLabel;
    pbTrkSequence: TPaintBox;
    sbTrkSeq: TScrollBar;
    pbTracker: TWheelPaintBox;
    sbTrkChn: TScrollBar;
    pnlTrkSupport: TPanel;
    lblTrkSupport: TLabel;
    btnTrkSupport: TButton;
    pgcTrk: TPageControl;
    tsTrkModule: TTabSheet;
    tsTrkInstruments: TTabSheet;
    pnlTrkInstrTop: TPanel;
    lblTrkInstrSel: TLabel;
    cboTrkInstrSel: TComboBox;
    btnTrkInstrAddTimeline: TButton;
    btnTrkInstrSaveWav: TButton;
    pnlTrkInstrInfo: TPanel;
    lblTrkInstrInfo: TLabel;
    pbTrkInstrWave: TWheelPaintBox;
    mnuTracker: TMenuItem;
    mnuTrkNew: TMenuItem;
    mnuTrkNewTracker: TMenuItem;
    mnuTrkPattern: TMenuItem;
    mnuTrkAddPattern: TMenuItem;
    mnuTrkDelPattern: TMenuItem;
    mnuTrkCell: TMenuItem;
    mnuTrkSetCell: TMenuItem;
    mnuTrkClearCell: TMenuItem;
    mnuTrkFillDemo: TMenuItem;
    mnuTrkTransport: TMenuItem;
    mnuTrkApplyXport: TMenuItem;
    mnuTrkPlay: TMenuItem;
    mnuTrkStop: TMenuItem;
    mnuTrkEdit: TMenuItem;
    mnuTrkUndo: TMenuItem;
    mnuTrkRedo: TMenuItem;
    mnuTrkImport: TMenuItem;
    mnuTrkImportMod: TMenuItem;
    mnuTrkImportXm: TMenuItem;
    mnuTrkImportMptm: TMenuItem;
    mnuTrkExport: TMenuItem;
    mnuTrkExportMod: TMenuItem;
    mnuTrkExportXm: TMenuItem;
    mnuTrkExportMptm: TMenuItem;
    pmTrkGrid: TPopupMenu;
    pmTrkSetCell: TMenuItem;
    pmTrkClearCell: TMenuItem;
    pmTrkFillDemo: TMenuItem;
    pmTrkGridSep1: TMenuItem;
    pmTrkUndo: TMenuItem;
    pmTrkRedo: TMenuItem;
    pmTrkGridSep2: TMenuItem;
    pmTrkPlay: TMenuItem;
    pmTrkStop: TMenuItem;
    pmTrkSeq: TPopupMenu;
    pmTrkAddPattern: TMenuItem;
    pmTrkDelPattern: TMenuItem;
    dlgOpenMod: TOpenDialog;
    dlgSaveMod: TSaveDialog;
    dlgOpenXm: TOpenDialog;
    dlgSaveXm: TSaveDialog;
    dlgOpenMptm: TOpenDialog;
    dlgSaveMptm: TSaveDialog;
    stbMain: TStatusBar;
    prgStatus: TProgressBar;
    dlgOpenFlac: TOpenDialog;
    dlgOpenAls: TOpenDialog;
    dlgOpenFlp: TOpenDialog;
    tmrUI: TTimer;
    tabBrowser: TTabSheet;
    pnlBrowserTop: TPanel;
    lblBrowserHint: TLabel;
    btnBrowserAddFolder: TButton;
    btnBrowserRefresh: TButton;
    btnBrowserImport: TButton;
    btnBrowserAddToSelected: TButton;
    tvBrowser: TTreeView;
    memBrowser: TMemo;
    lblBrowserFloating: TLabel;
    tabScope: TTabSheet;
    pnlScopeTop: TPanel;
    lblScopeSignal: TLabel;
    lblScopeMode: TLabel;
    cboScopeSignal: TComboBox;
    cboScopeMode: TComboBox;
    chkScopeLive: TCheckBox;
    pnlScopeReadout: TPanel;
    memScopeReadout: TMemo;
    pbScope: TPaintBox;
    tabAdvDsp: TTabSheet;
    pnlAdvDspTop: TPanel;
    lblAdvDspSignal: TLabel;
    lblAdvDspProcess: TLabel;
    lblAdvDspParam: TLabel;
    cboAdvDspSignal: TComboBox;
    cboAdvDspProcess: TComboBox;
    edtAdvDspParam: TEdit;
    memAdvDspReadout: TMemo;
    tabAI: TTabSheet;
    pcAiMain: TPageControl;
    tsAiSelect: TTabSheet;
    tsAiMcp: TTabSheet;
    tsAiRecordings: TTabSheet;
    tsAiLyrics: TTabSheet;
    tsAiGeneration: TTabSheet;
    lblAiProvider: TLabel;
    lblAiKey: TLabel;
    cboAiProvider: TComboBox;
    edtAiApiKey: TEdit;
    lblAiModel: TLabel;
    cboAiModel: TComboBox;
    lblAiMcpName: TLabel;
    lblAiMcpCmd: TLabel;
    edtAiMcpName: TEdit;
    edtAiMcpCommand: TEdit;
    lblAiMcpToken: TLabel;
    edtAiMcpToken: TEdit;
    btnAiMcpTest: TButton;
    lblAiMcpHint: TLabel;
    chkAiMcpExpose: TCheckBox;
    lblAiMcpExposePort: TLabel;
    edtAiMcpExposePort: TEdit;
    chkAiMcpAllowDestructive: TCheckBox;
    lblAiMcpBind: TLabel;
    edtAiMcpBind: TEdit;
    chkAiMcpTls: TCheckBox;
    lblAiMcpTlsPort: TLabel;
    edtAiMcpTlsPort: TEdit;
    lblAiMcpCert: TLabel;
    edtAiMcpCert: TEdit;
    lblAiMcpKey: TLabel;
    edtAiMcpKey: TEdit;
    btnAiMcpTestLocal: TButton;
    btnAiMcpTestTls: TButton;
    edtAiMcpTestUrl: TEdit;
    chkAiMcpSelfSigned: TCheckBox;
    memAiMcpProviders: TMemo;
    lstAiMcpServers: TListBox;
    splAiLog: TSplitter;
    memAiLog: TMemo;
    btnAiSave: TButton;
    btnAiTest: TButton;
    btnAiDelete: TButton;
    pnlAiChat: TPanel;
    edtAiPrompt: TEdit;
    btnAiSend: TButton;
    btnAiClear: TButton;
    btnAiGenerateTune: TButton;
    pnlAiSuno: TPanel;
    pnlAiLuma: TPanel;
    lblLumaKind, lblLumaModel, lblLumaPrompt, lblLumaAspect, lblLumaResolution,
      lblLumaDuration, lblLumaFormat, lblLumaStartFrame: TLabel;
    cboLumaKind, cboLumaModel, cboLumaAspect, cboLumaResolution, cboLumaDuration,
      cboLumaFormat: TComboBox;
    lblLumaEndFrame, lblLumaImageRef, lblLumaImageRefWeight, lblLumaStyleRef,
      lblLumaCharRef, lblLumaModifyRef: TLabel;
    edtLumaPrompt, edtLumaStartFrame, edtLumaEndFrame, edtLumaImageRef,
      edtLumaImageRefWeight, edtLumaStyleRef, edtLumaStyleWeight, edtLumaCharRef,
      edtLumaModifyRef, edtLumaModifyWeight: TEdit;
    chkLumaLoop: TCheckBox;
    chkLumaTabOnly: TCheckBox;
    btnLumaTest, btnLumaGenerate, btnLumaCancel, btnLumaConcepts, btnLumaOpen: TButton;
    lblLumaConcepts: TLabel;
    lstLumaConcepts: TListBox;
    lblSunoPrompt: TLabel;
    edtSunoPrompt: TEdit;
    memSunoLyrics: TRichEdit;
    dlgSaveLyrics: TSaveDialog;
    pmSunoLyrics: TPopupMenu;
    pmSunoLyricsClear: TMenuItem;
    pmSunoLyricsSep: TMenuItem;
    pmSunoLyricsSave: TMenuItem;
    lblSunoLyricsCount: TLabel;
    chkSunoInstrumental: TCheckBox;
    lblSunoBaseUrl: TLabel;
    edtSunoBaseUrl: TEdit;
    btnSunoTest: TButton;
    cboSunoApi, cboSunoModel: TComboBox;
    edtSunoCallback, edtSunoTitle: TEdit;
    edtSunoStyle: TRichEdit;
    chkSunoCustom: TCheckBox;
    btnSunoGenerate, btnSunoCancel: TButton;
    lblSunoApi, lblSunoModel, lblSunoCallback, lblSunoStyle, lblSunoTitle: TLabel;
    chkSunoAdvanced: TCheckBox;
    lblSunoRefHint: TLabel;
    lstSunoRefs: TListBox;
    btnSunoRefAdd, btnSunoRefRemove, btnSunoRefRefresh, btnSunoRefRecord: TButton;
    dlgSunoRefOpen: TOpenDialog;
    lblSunoRefMode, lblSunoContinueAt: TLabel;
    cboSunoRefMode: TComboBox;
    edtSunoContinueAt: TEdit;
    pnlAiVoice: TPanel;
    lblVoiceHint: TLabel;
    mnuScope: TMenuItem;
    mnuScopeAnalyze: TMenuItem;
    pmScope: TPopupMenu;
    pmScopeAnalyze: TMenuItem;
    mnuAdvDsp: TMenuItem;
    mnuAdvDspRun: TMenuItem;
    pmAdvDsp: TPopupMenu;
    pmAdvDspRun: TMenuItem;
    mnuAi: TMenuItem;
    mnuAiCredentials: TMenuItem;
    mnuAiSave: TMenuItem;
    mnuAiTest: TMenuItem;
    mnuAiDelete: TMenuItem;
    mnuAiMcp: TMenuItem;
    mnuAiMcpAdd: TMenuItem;
    mnuAiMcpRemove: TMenuItem;
    mnuAiChat: TMenuItem;
    mnuAiSend: TMenuItem;
    mnuAiClear: TMenuItem;
    mnuAiSuno: TMenuItem;
    mnuAiOpenCache: TMenuItem;
    mnuAiVoice: TMenuItem;
    mnuAiMixAssist: TMenuItem;
    mnuAiMixAnalyze: TMenuItem;
    mnuAiMixPreview: TMenuItem;
    mnuAiMixCompare: TMenuItem;
    mnuAiMixApply: TMenuItem;
    mnuAiMixReject: TMenuItem;
    mnuAiMasterAssist: TMenuItem;
    mnuAiMasterSuggest: TMenuItem;
    mnuAiMasterPreview: TMenuItem;
    mnuAiMasterCompare: TMenuItem;
    mnuAiMasterApply: TMenuItem;
    mnuAiMasterReject: TMenuItem;
    pmAi: TPopupMenu;
    pmAiSave: TMenuItem;
    pmAiTest: TMenuItem;
    pmAiDelete: TMenuItem;
    pmAiSep1: TMenuItem;
    pmAiMcpAdd: TMenuItem;
    pmAiMcpRemove: TMenuItem;
    pmAiSep2: TMenuItem;
    pmAiSend: TMenuItem;
    pmAiClear: TMenuItem;
    pmAiSep3: TMenuItem;
    pmAiSuno: TMenuItem;
    pmAiOpenCache: TMenuItem;
    pmAiVoice: TMenuItem;
    pmAiSep4: TMenuItem;
    pmAiMixAnalyze: TMenuItem;
    pmAiMixPreview: TMenuItem;
    pmAiMixCompare: TMenuItem;
    pmAiMixApply: TMenuItem;
    pmAiMixReject: TMenuItem;
    pmAiSep5: TMenuItem;
    pmAiMasterSuggest: TMenuItem;
    pmAiMasterPreview: TMenuItem;
    pmAiMasterCompare: TMenuItem;
    pmAiMasterApply: TMenuItem;
    pmAiMasterReject: TMenuItem;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormResize(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure DeleteActiveChannel;
    procedure btnRefreshSystemClick(Sender: TObject);
    procedure btnOpenConfigDirClick(Sender: TObject);
    procedure btnOpenLogDirClick(Sender: TObject);
    procedure btnApplyLevelClick(Sender: TObject);
    procedure btnEmitInfoClick(Sender: TObject);
    procedure btnEmitWarnClick(Sender: TObject);
    procedure btnEmitErrorClick(Sender: TObject);
    procedure btnClearLogViewClick(Sender: TObject);
    procedure btnRunSelfTestClick(Sender: TObject);
    procedure btnCancelJobsClick(Sender: TObject);
    procedure btnSecretSetClick(Sender: TObject);
    procedure btnSecretGetClick(Sender: TObject);
    procedure btnSecretDeleteClick(Sender: TObject);
    procedure btnAudioStartClick(Sender: TObject);
    procedure btnAudioStopClick(Sender: TObject);
    procedure btnAudioToneClick(Sender: TObject);
    procedure btnAudioResetClick(Sender: TObject);
    procedure btnAudioReopenClick(Sender: TObject);
    procedure btnSecSealClick(Sender: TObject);
    procedure btnSecVerifyClick(Sender: TObject);
    procedure btnSecProbeClick(Sender: TObject);
    procedure btnDspAnalyzeClick(Sender: TObject);
    procedure chkDspLiveClick(Sender: TObject);
    procedure pbSpectrumPaint(Sender: TObject);
    procedure btnGraphBuildClick(Sender: TObject);
    procedure btnGraphPlayClick(Sender: TObject);
    procedure chkGraphLiveClick(Sender: TObject);
    procedure pbGraphPaint(Sender: TObject);
    procedure tmrUITimer(Sender: TObject);
    procedure btnProjectNewClick(Sender: TObject);
    procedure btnProjectOpenClick(Sender: TObject);
    procedure btnProjectSaveClick(Sender: TObject);
    procedure btnProjectSaveAsClick(Sender: TObject);
    procedure btnProjectApplyClick(Sender: TObject);
    procedure btnUndoClick(Sender: TObject);
    procedure btnRedoClick(Sender: TObject);
    procedure btnAddGainNodeClick(Sender: TObject);
    procedure btnRemoveLastNodeClick(Sender: TObject);
    procedure cboAutosaveIntervalChange(Sender: TObject);
    procedure btnAutosaveNowClick(Sender: TObject);
    procedure btnRecoverClick(Sender: TObject);
    procedure btnWavImportClick(Sender: TObject);
    procedure btnWavPlayClick(Sender: TObject);
    procedure btnWavExportToneClick(Sender: TObject);
    procedure btnWavRoundTripClick(Sender: TObject);
    procedure btnMp3ImportClick(Sender: TObject);
    procedure btnMp3ReadTagsClick(Sender: TObject);
    procedure btnMp3ExportToneClick(Sender: TObject);
    procedure btnMp3RoundTripClick(Sender: TObject);
    procedure btnMp3ToTimelineClick(Sender: TObject);
    procedure btnMp3PlayClick(Sender: TObject);
    procedure btnMp3StopClick(Sender: TObject);
    procedure btnMp4ProbeClick(Sender: TObject);
    procedure btnMp4ImportClick(Sender: TObject);
    procedure btnMp4ExportToneClick(Sender: TObject);
    procedure btnMp4RoundTripClick(Sender: TObject);
    procedure btnMp4ToTimelineClick(Sender: TObject);
    procedure btnMp4PlayClick(Sender: TObject);
    procedure btnMp4StopClick(Sender: TObject);
    procedure cboMidiClipChange(Sender: TObject);
    procedure btnMidiAddClipClick(Sender: TObject);
    procedure btnMidiAddTrackClick(Sender: TObject);
    procedure btnMidiAddNoteClick(Sender: TObject);
    procedure btnMidiDelNoteClick(Sender: TObject);
    procedure btnMidiQuantizeClick(Sender: TObject);
    procedure btnMidiHumanizeClick(Sender: TObject);
    procedure btnMidiPlayClick(Sender: TObject);
    procedure btnMidiStopClick(Sender: TObject);
    procedure mnuMidiRecordClick(Sender: TObject);
    procedure btnMidiImportSMFClick(Sender: TObject);
    procedure btnMidiExportSMFClick(Sender: TObject);
    procedure btnMidiUndoClick(Sender: TObject);
    procedure btnMidiRedoClick(Sender: TObject);
    procedure btnMidiDemoClick(Sender: TObject);
    procedure btnSettingsSaveClick(Sender: TObject);
    procedure btnRegRegisterClick(Sender: TObject);
    procedure btnRegUnregisterClick(Sender: TObject);
    procedure btnRegCheckUpdateClick(Sender: TObject);
    procedure btnRegInstallUpdateClick(Sender: TObject);
    procedure btnSettingsReloadClick(Sender: TObject);
    procedure btnSettingsBrowseDirClick(Sender: TObject);
    {$IFNDEF FPC}
    procedure edtProjectNameExit(Sender: TObject);
    procedure edtProjectAuthorExit(Sender: TObject);
    procedure btnKeyHookAssignClick(Sender: TObject);
    procedure btnKeyHookSaveClick(Sender: TObject);
    procedure btnKeyHookRestoreClick(Sender: TObject);
    procedure btnKeyHookToggleClick(Sender: TObject);
    {$ENDIF}
    procedure cboSetThemeChange(Sender: TObject);
    procedure btnBrowserAddFolderClick(Sender: TObject);
    procedure btnBrowserRefreshClick(Sender: TObject);
    procedure btnBrowserImportClick(Sender: TObject);
    procedure btnBrowserAddToSelectedClick(Sender: TObject);
    procedure tvBrowserExpanding(Sender: TObject; Node: TTreeNode; var AllowExpansion: Boolean);
    procedure tvBrowserMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure pbPianoRollPaint(Sender: TObject);
    procedure pbPianoRollMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure pbPianoRollMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure pbPianoRollMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure chkMidiScaleHighlightClick(Sender: TObject);
    procedure cboMidiScaleChange(Sender: TObject);
    procedure btnTlDemoClick(Sender: TObject);
    procedure btnTlAddTrackClick(Sender: TObject);
    procedure btnTlAddClipClick(Sender: TObject);
    procedure btnTlSplitClick(Sender: TObject);
    procedure btnTlDeleteClipClick(Sender: TObject);
    procedure btnTlRemoveTrackClick(Sender: TObject);
    procedure pmTimelinePopup(Sender: TObject);
    procedure pmTimelineRulerPopup(Sender: TObject);
    procedure btnTlSplitRangeClick(Sender: TObject);
    procedure btnTlDeleteRangeClick(Sender: TObject);
    procedure btnTlFadeInRangeClick(Sender: TObject);
    procedure btnTlFadeOutRangeClick(Sender: TObject);
    procedure btnTlLoopToRangeClick(Sender: TObject);
    procedure btnTlNormalizeRangeClick(Sender: TObject);
    procedure btnTlReverseRangeClick(Sender: TObject);
    procedure TlClipTempoClick(Sender: TObject);
    procedure TlFxMenuClick(Sender: TObject);
    procedure TlUndoEffectClick(Sender: TObject);
    procedure TlFxFadeInClick(Sender: TObject);
    procedure TlFxFadeOutClick(Sender: TObject);
    procedure btnTlAddMarkerHereClick(Sender: TObject);
    procedure btnTlGoStartClick(Sender: TObject);
    procedure btnTlGoEndClick(Sender: TObject);
    procedure btnTlZoomFitClick(Sender: TObject);
    procedure mnuTimelineClick(Sender: TObject);
    procedure btnTlZoomInClick(Sender: TObject);
    procedure btnTlZoomOutClick(Sender: TObject);
    procedure btnTlUndoClick(Sender: TObject);
    procedure btnTlRedoClick(Sender: TObject);
    procedure btnTlPlayClick(Sender: TObject);
    procedure btnTlStopClick(Sender: TObject);
    procedure TlPlayFromBeginningClick(Sender: TObject);
    procedure TlPlayFromCurrentClick(Sender: TObject);
    procedure TlPlayReverseClick(Sender: TObject);
    procedure TlPlayPingPongClick(Sender: TObject);
    procedure pmTlExportWavClick(Sender: TObject);
    procedure pmTlExportMp3Click(Sender: TObject);
    procedure pmTlExportMp4Click(Sender: TObject);
    procedure pmTlExportFlacClick(Sender: TObject);
    procedure RunTimelineExport(AFilterIndex: Integer);
    procedure StartTimelineExportJob(const ADest: string;
      ARangeStart: Double = 0; ARangeEnd: Double = 0);
    procedure TlSaveSelectionClick(Sender: TObject);
    procedure FinishTimelineExport;
    procedure FinishTimelinePrepare;
    procedure BeginTimelineAudio;
    procedure ParkTimelineCache;
    procedure TrackTimelineExportStage;
    procedure btnTlCutClick(Sender: TObject);
    procedure btnTlCopyClick(Sender: TObject);
    procedure btnTlPasteClick(Sender: TObject);
    procedure pmTlCopySelectionClick(Sender: TObject);
    procedure pmTlPasteSelectionClick(Sender: TObject);
    procedure btnTlTrackUpClick(Sender: TObject);
    procedure btnTlTrackDownClick(Sender: TObject);
    procedure pmTlMuteTrackClick(Sender: TObject);
    procedure pmTlRenameTrackClick(Sender: TObject);
    procedure pmTlNavNextClick(Sender: TObject);
    procedure pmTlNavPrevClick(Sender: TObject);
    procedure pmTlJumpElementStartClick(Sender: TObject);
    procedure pmTlJumpElementEndClick(Sender: TObject);
    function TlNavStepSeconds: Double;
    function TlNavTargetTrack: TTimelineTrack;
    procedure btnTlLoopStartClick(Sender: TObject);
    procedure btnTlLoopEndClick(Sender: TObject);
    procedure btnTlLoopToggleClick(Sender: TObject);
    procedure mnuTlImportWavClick(Sender: TObject);
    procedure mnuTlImportFlacClick(Sender: TObject);
    procedure mnuTlImportModClick(Sender: TObject);
    procedure mnuTlImportXmClick(Sender: TObject);
    procedure mnuTlImportMptmClick(Sender: TObject);
    procedure mnuTlImportAlsClick(Sender: TObject);
    procedure mnuTlImportFlpClick(Sender: TObject);
    procedure cboTlSnapChange(Sender: TObject);
    procedure edtTlTempoExit(Sender: TObject);
    procedure chkTlMetronomeClick(Sender: TObject);
    procedure TlWarpMenuClick(Sender: TObject);
    procedure tbTlMasterVolChange(Sender: TObject);
    procedure sbTlHorzChange(Sender: TObject);
    procedure sbTlVertChange(Sender: TObject);
    procedure pbTimelinePaint(Sender: TObject);
    procedure pbTlMetersPaint(Sender: TObject);
    procedure DrawTimelineSpectrum(ACanvas: TCanvas; const ARect: TRect);
    procedure UpdateTimelineMeterChannel(var AMeter: Single; APeak: Single);
    procedure pbTimelineMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure pbTimelineMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure pbTimelineMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure pbTimelineMouseWheel(Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
    procedure pbTimelineDragOver(Sender, Source: TObject; X, Y: Integer;
      State: TDragState; var Accept: Boolean);
    procedure pbTimelineDragDrop(Sender, Source: TObject; X, Y: Integer);
    {$IFNDEF FPC}
    { OS Explorer file drag-in - registered on pbTimeline via DragAcceptFiles
      in FormCreate. VCL/Windows only: see the Phase 33 Browser-tab comment
      above BrowserIsAudioExt for why in-app TTreeView dragging didn't need
      this, but dropping straight from Explorer does. }
    procedure WMDropFiles(var Msg: TWMDropFiles); message WM_DROPFILES;
    {$ENDIF}
    procedure cboRecPunchChange(Sender: TObject);
    procedure chkRecLoopClick(Sender: TObject);
    procedure btnRecArmClick(Sender: TObject);
    procedure btnRecSavedClick(Sender: TObject);
    procedure btnRecCommitClick(Sender: TObject);
    procedure btnRecScanClick(Sender: TObject);
    procedure btnRecSaveTakeClick(Sender: TObject);
    procedure btnRecAddTakeToTimelineClick(Sender: TObject);
    procedure btnRecCommitCompClick(Sender: TObject);
    procedure btnRecResetCompClick(Sender: TObject);
    procedure pbRecTakesMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure pbRecTakesMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure EnsureComp;
    function RecXToSeconds(X: Integer): Double;
    procedure pbRecTakesPaint(Sender: TObject);
    procedure pbRecTakesMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    function RecSelectedTakeIndex: Integer;
    procedure cboMixStripChange(Sender: TObject);
    procedure cboMixTrackLinkChange(Sender: TObject);
    procedure btnMixAddTrackClick(Sender: TObject);
    procedure btnMixAddBusClick(Sender: TObject);
    procedure btnMixAddAuxClick(Sender: TObject);
    procedure btnMixAddVCAClick(Sender: TObject);
    procedure btnMixRemoveClick(Sender: TObject);
    procedure btnMixApplyClick(Sender: TObject);
    procedure chkMixMuteClick(Sender: TObject);
    procedure chkMixSoloClick(Sender: TObject);
    procedure btnMixAddEQClick(Sender: TObject);
    procedure btnMixDelInsertClick(Sender: TObject);
    procedure btnMixPreviewClick(Sender: TObject);
    procedure btnMixUndoClick(Sender: TObject);
    procedure btnMixRedoClick(Sender: TObject);
    procedure pbMixerPaint(Sender: TObject);
    procedure pbMixerMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure pbMixerMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure pbMixerMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure pbMixerDragOver(Sender, Source: TObject; X, Y: Integer;
      State: TDragState; var Accept: Boolean);
    procedure pbMixerDragDrop(Sender, Source: TObject; X, Y: Integer);
    procedure pbMixerDblClick(Sender: TObject);
    procedure pmMixerPopup(Sender: TObject);
    procedure btnMixAddVSTClick(Sender: TObject);
    procedure MixModMenuClick(Sender: TObject);
    procedure btnMixEditVSTClick(Sender: TObject);
    procedure cboMixAutoParamChange(Sender: TObject);
    procedure cboMixAutoModeChange(Sender: TObject);
    procedure tbMixZoomChange(Sender: TObject);
    procedure pbMixAutoPaint(Sender: TObject);
    procedure pbMixAutoMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure pbMixAutoMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure pbMixAutoMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure btnMixMeterApplyClick(Sender: TObject);
    procedure RefreshMixAutomationParams(AStrip: TMixStrip);
    procedure DrawMixStrip(ABuf: TCanvas; AX, AWidth, AHeight: Integer;
      const AStrip: TMixStrip; ASelected: Boolean; out ARect: TRect);
    procedure cboTrkPatternChange(Sender: TObject);
    procedure mnuTrkNewTrackerClick(Sender: TObject);
    procedure btnTrkApplyXportClick(Sender: TObject);
    procedure btnTrkAddPatternClick(Sender: TObject);
    procedure btnTrkDelPatternClick(Sender: TObject);
    procedure btnTrkSetCellClick(Sender: TObject);
    procedure btnTrkClearCellClick(Sender: TObject);
    procedure btnTrkFillDemoClick(Sender: TObject);
    procedure btnTrkPlayClick(Sender: TObject);
    procedure btnTrkStopClick(Sender: TObject);
    procedure btnTrkUndoClick(Sender: TObject);
    procedure btnTrkRedoClick(Sender: TObject);
    procedure btnTrkImportModClick(Sender: TObject);
    procedure btnTrkExportModClick(Sender: TObject);
    procedure btnTrkImportXmClick(Sender: TObject);
    procedure btnTrkExportXmClick(Sender: TObject);
    procedure btnTrkImportMptmClick(Sender: TObject);
    procedure btnTrkExportMptmClick(Sender: TObject);
    procedure pbTrackerPaint(Sender: TObject);
    procedure btnTrkSupportClick(Sender: TObject);
    procedure pbTrackerMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure pbTrackerMouseWheel(Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
    procedure sbTrkChnChange(Sender: TObject);
    procedure RefreshTrkInstrTab;
    procedure cboTrkInstrSelChange(Sender: TObject);
    procedure btnTrkInstrAddTimelineClick(Sender: TObject);
    procedure btnTrkInstrSaveWavClick(Sender: TObject);
    procedure pbTrkInstrWavePaint(Sender: TObject);
    procedure pbTrkSequencePaint(Sender: TObject);
    procedure pbTrkSequenceMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure sbTrkSeqChange(Sender: TObject);
    procedure btnScopeAnalyzeClick(Sender: TObject);
    procedure chkScopeLiveClick(Sender: TObject);
    procedure pbScopePaint(Sender: TObject);
    procedure btnAdvDspRunClick(Sender: TObject);
    procedure cboAiProviderChange(Sender: TObject);
    procedure cboAiModelChange(Sender: TObject);
    procedure btnAiSaveClick(Sender: TObject);
    procedure btnAiTestClick(Sender: TObject);
    procedure btnAiDeleteClick(Sender: TObject);
    procedure btnAiMcpAddClick(Sender: TObject);
    procedure btnAiMcpRemoveClick(Sender: TObject);
    procedure btnAiMcpTestClick(Sender: TObject);
    procedure chkAiMcpExposeClick(Sender: TObject);
    procedure btnAiMcpTestLocalClick(Sender: TObject);
    procedure btnAiMcpTestTlsClick(Sender: TObject);
    procedure btnAiSendClick(Sender: TObject);
    procedure btnAiClearClick(Sender: TObject);
    procedure btnAiGenerateTuneClick(Sender: TObject);
    procedure btnSunoGenerateClick(Sender: TObject);
    procedure btnLumaTestClick(Sender: TObject);
    procedure btnLumaGenerateClick(Sender: TObject);
    procedure GenerateMusicTabPdf;
    procedure btnLumaCancelClick(Sender: TObject);
    procedure btnLumaConceptsClick(Sender: TObject);
    procedure btnLumaOpenClick(Sender: TObject);
    procedure FinishLumaJob;
    procedure cboLumaKindChange(Sender: TObject);
    procedure btnSunoTestClick(Sender: TObject);
    procedure btnSunoCancelClick(Sender: TObject);
    procedure cboSunoApiChange(Sender: TObject);
    procedure chkSunoAdvancedClick(Sender: TObject);
    procedure chkSunoCustomClick(Sender: TObject);
    procedure memSunoLyricsChange(Sender: TObject);
    procedure pmSunoLyricsPopup(Sender: TObject);
    procedure pmSunoLyricsClearClick(Sender: TObject);
    procedure pmSunoLyricsSaveClick(Sender: TObject);
    procedure cboSunoRefModeChange(Sender: TObject);
    procedure btnSunoRefAddClick(Sender: TObject);
    procedure btnSunoRefRemoveClick(Sender: TObject);
    procedure btnSunoRefRefreshClick(Sender: TObject);
    procedure btnSunoRefRecordClick(Sender: TObject);
    procedure mnuAiOpenCacheClick(Sender: TObject);
    procedure FinishSunoJob;
    procedure RestoreStartupProject;
    procedure ShowLogClick(Sender: TObject);
    procedure OpenBrowserWindowClick(Sender: TObject);
    procedure BrowserWindowFormClose(Sender: TObject; var Action: TCloseAction);
    function ActiveWorkspacePage: TTabSheet;
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure RememberProject(const AFileName: string);
    procedure RefreshRecentProjects;
    procedure RecentProjectClick(Sender: TObject);
    function CurrentSunoBaseUrl: string;
    function CurrentSunoModel: string;
    procedure SetSunoModel(const AModelId: string);
    procedure ApplySunoAutoConfig;
    procedure LoadSunoRefs;
    procedure SaveSunoRefs;
    function SelectedSunoRefPath: string;
    procedure DrainSunoRefRecording;
    procedure btnVoiceRecordClick(Sender: TObject);
    procedure btnHelpAboutClick(Sender: TObject);
    procedure btnAboutClick(Sender: TObject);
    procedure pgcChange(Sender: TObject);
    procedure btnAiAnalyzeMixClick(Sender: TObject);
    procedure btnAiMixPreviewClick(Sender: TObject);
    procedure btnAiMixCompareClick(Sender: TObject);
    procedure btnAiMixApplyClick(Sender: TObject);
    procedure btnAiMixRejectClick(Sender: TObject);
    procedure btnAiSuggestMasteringClick(Sender: TObject);
    procedure btnAiMasterPreviewClick(Sender: TObject);
    procedure btnAiMasterCompareClick(Sender: TObject);
    procedure btnAiMasterApplyClick(Sender: TObject);
    procedure btnAiMasterRejectClick(Sender: TObject);
    procedure cboColorThemeChange(Sender: TObject);
    procedure btnColorThemeSaveClick(Sender: TObject);
    procedure btnColorThemeResetClick(Sender: TObject);
    procedure btnColorThemeExportClick(Sender: TObject);
    procedure btnColorThemeImportClick(Sender: TObject);
    procedure cboSetMidiInDeviceChange(Sender: TObject);
    procedure cboSetMidiOutDeviceChange(Sender: TObject);
    procedure btnSetMidiRefreshClick(Sender: TObject);
    procedure btnSetMidiPanicClick(Sender: TObject);
    procedure lbColorSwatchesClick(Sender: TObject);
    procedure pbColorPreviewPaint(Sender: TObject);
    procedure btnColorPickClick(Sender: TObject);
    procedure btnColorsSaveClick(Sender: TObject);
    procedure cboFadeDisplayChange(Sender: TObject);
    procedure btnColorsResetThemeClick(Sender: TObject);
    procedure lvLogCustomDrawItem(Sender: TCustomListView; Item: TListItem;
      State: TCustomDrawState; var DefaultDraw: Boolean);
  private
    procedure SendAiChatPrompt(const APrompt: string; ABatchConfirm: Boolean = False);
    procedure GenerateTimelineTuneFromAI;
    function PopulateAiModelList(const APid, AKey: string): Boolean;
    procedure TryAutoPopulateAiModelList(const APid: string);
    procedure RunVoicePipeline;
    procedure AdvanceTimelinePlayback;
    procedure StopTimelinePlayback;
    procedure StopAllPlayback;
    procedure StartTimelinePlayback(AFromBeginning, AReverse, APingPong: Boolean);
    function TrkSeqStepWidth: Integer;
    function RenderMixAnalysis: TAudioAnalysisResult;
    function RenderProjectMixOffline(ASeconds: Double; ASampleRate: Integer): TOfflineResult;
    procedure EnsureMixSession;
    procedure EnsureMasterSession;
    procedure LogAiToolResult(const AText: string);
  private
    FLogShown: Integer;
    FTrackedJobs: TList;
    FTonePlaying: Boolean;
    FDspDb: array of Double;          // one-sided spectrum, dBFS per bin
    FDspNyquist: Double;
    FDspReadout: string;
    FGraph: TAudioGraph;
    FGraphPlaying: Boolean;
    FProject: TProjectDocument;
    FCmds: TCommandManager;
    FMixSession: TAIMixingSession;
    FMasterSession: TAIMasteringSession;
    FAiSessionDoc: TProjectDocument;   // which FProject FMixSession/FMasterSession were built for
    FRecovery: TProjectRecoveryManager;
    FRecoverySessionActive: Boolean;
    FWindowStateReady: Boolean;
    FLogViewer: TfrmLogViewer;
    FBrowserWindow: TfrmBrowserWindow;
    FOpenVST2Editors: TList<TfrmVST2Editor>;   // non-owning: each frees itself via caFree
    FSunoJob: TSunoGenerationJob;
    FLumaJob: TLumaGenerationJob;
    FLumaLastResult: string;
    FTimelineExportJob: TTimelineExportJob;
    FTlPrepJob: TTimelinePrepareJob;    // background decode/stretch before Play (see FinishTimelinePrepare)
    FTlPrepCancelled: Boolean;
    FTlCacheHolder: TTimelinePlayer;    // spare player holding decoded/stretched caches between Plays
    FTlExportLastStage: string;   // last 'Stage n/6' prefix already echoed to the Timeline log
    FSunoTrackId: Integer;
    FSunoPosition: Double;
    FSunoRefs: TStringList;        // local paths of recordings offered to Suno as Cover/Extend reference audio
    FSunoRefCapture: TLiveCapture; // non-nil while the Recordings-tab "Record" button is active
    FSunoRefCapturePath: string;
    FWavPath: string;
    FWavSource: IAudioSource;
    FWavPlaying: Boolean;
    FMp3Path: string;
    FMp3Source: IAudioSource;
    FMp4Path: string;
    FMp4Source: IAudioSource;
    FTlView: TTimelineView;
    FTlSelClipId: Integer;
    FTlDragging: Boolean;
    FTlDragMouseStartSec: Double;
    FTlDragClipStartSec: Double;
    FTlScrollGuard: Boolean;
    FTlVolGuard: Boolean;
    FTlPlayer: TTimelinePlayer;
    FWarpClipId: Integer;
    FWarpMarkers: TWarpMarkers;
    FTlMixerProc: TMixerProcessor;   // owned; feeds any track a Mixer strip's InputSourceId names
    FTlPlaying: Boolean;
    { True for the duration of a synchronous ShowStatusProgress/
      HideStatusProgress-bracketed operation - tells RefreshJobs (tmrUITimer,
      500ms) not to stomp stbMain/prgStatus with the background-jobs summary
      while a foreground operation owns them. }
    FSyncProgressActive: Boolean;
    FTlCtxTrackId: Integer;
    FTlSelectedTrackId: Integer;  // persistent destination selected in the Timeline
    FTlExtraTrackIds: TArray<Integer>;  // additional tracks selected via Ctrl/Shift-click (highlight only)
    FTlVScrollY: Integer;         // px, vertical scroll of the channel list; the ruler
                                   // (drawn at a fixed absolute y) and the title bands
                                   // above each track are the only things this leaves
                                   // untouched - see TlTrackTop/sbTlVertChange
    FTlRulerCtxActive: Boolean;   // right-click landed in the ruler - see pbTimelineMouseUp
    FTlBuffer: TBitmap;
    { Out L/R level graphs on the Timeline toolbar (pbTlMeters) - smoothed
      0..1 peak with VU-style decay, read from App.Audio.OutputPeak while
      FTlPlaying; StartTimelinePlayback/StopTimelinePlayback reset both to 0
      so the graphs only move during playback and go idle when it stops. }
    FTlMeterL: Single;
    FTlMeterR: Single;
    FTlMeterBuffer: TBitmap;
    { Single master-output spectrum drawn in the Timeline's top-left corner
      (over the track-header column, so it resizes with HeaderWidth). Fed from
      the engine's post-mixer output tap, i.e. exactly what the mixer sends out. }
    FTlSpectrum: TSpectrumAnalyzer;
    FTlSpecDb: array of Double;
    FTlSpecTap: array of Single;
    FTlSpecRate: Integer;
    FTlSpecActive: Boolean;
    FTlTrimming: Boolean;
    FTlTrimClipId: Integer;
    FTlTrimEdge: TClipEdge;
    FTlFadeDragging: Boolean;
    FTlFadeClipId: Integer;
    FTlFadeEdge: TClipEdge;
    FTlSelClipIds: TArray<Integer>;     // multi-select, in addition to FTlSelClipId (the "primary"/anchor)
    FTlDragIds: TArray<Integer>;        // snapshot of the full selection at drag-start, index-parallel to...
    FTlMultiDragStartSecs: TArray<Double>;  // ...each clip's StartSeconds at drag-start
    FTlMultiDragStartTrackIdx: TArray<Integer>;  // ...and each clip's track INDEX at drag-start
    FTlDragStartTrackIdx: Integer;       // track index under the cursor when the drag began (-1 if none)
    FTlRubberSelecting: Boolean;
    FTlRubberStartX, FTlRubberStartY: Integer;
    FTlRubberX, FTlRubberY: Integer;
    FTlClipboard: TClipState;
    FTlHaveClipboard: Boolean;
    { multi-clip "selection" clipboard for Copy Selection/Paste Selection:
      every clip overlapping the active range selection, across every
      channel, captured with its offset from the range start and its
      channel index relative to the channel that was active at copy time -
      so Paste Selection can drop the whole group at the playhead, anchored
      on whichever channel is active when you paste. }
    FTlSelectionClipboard: TArray<TClipState>;
    FTlSelectionClipboardRelStart: TArray<Double>;
    FTlSelectionClipboardRelTrack: TArray<Integer>;
    FTlHaveSelectionClipboard: Boolean;
    { time-range ("section") selection: an independent drag-to-select gesture
      on the ruler, spanning every track (not one clip's worth of pixels like
      the rubber-band above). Highlighted in pbTimelinePaint and consumed by
      the ruler-menu range actions (Split at Range Edges / Delete Range /
      Set Loop to Selection) below. }
    FTlRangeActive: Boolean;
    FTlRangeDragging: Boolean;
    { Key hook set for the Timeline rubber-band clip selection (empty-lane
      drag). Default Shift; kept as a field so the binding can be changed
      later without touching the mouse handler. Ctrl is reserved for range
      highlight. }
    FTlRubberBandMods: TShiftState;
    FMixAutoRegionDragging, FMixAutoRegionActive: Boolean;
    FMixAutoRegionX0, FMixAutoRegionX1: Integer;
    FRecRegionDragging, FRecRegionActive: Boolean;
    FRecRegionX0, FRecRegionX1: Integer;
    FTlRangeAnchorSec: Double;
    FTlRangeStartSec, FTlRangeEndSec: Double;
    FTlRangeMoving: Boolean;     // right-drag repositions the selected range (popup suppressed once it moves)
    FTlRangeMoveMoved: Boolean;
    FTlRangeMoveLastSec: Double;
    FTlRangeMoveDownX: Integer;
    FTlMiddlePanning: Boolean;   // middle-mouse-button drag-to-scroll (see pbTimelineMouseDown/Move/Up)
    FTlMiddlePanLastX: Integer;
    { left-button drag on the header/lane boundary resizes the track-header
      column (FTlView.HeaderWidth); persisted per-project (TTimeline.HeaderWidth). }
    FTlHeaderResizing: Boolean;
    FTlHeaderResizeStartX, FTlHeaderResizeStartWidth: Integer;
    FTlWaveformWarned: TStringList;   { source ids already reported to memTimeline - see pbTimelinePaint }
    FColorPreviewColor: TColor;   { swatch colour for pbColorPreview - a plain TColor field, not the
      paintbox's own property, so pbColorPreviewPaint has something to read on every repaint (paint
      via Canvas, not a themed control's .Color, so it renders correctly under an active VCL style) }
    FColorSwatchList: TArray<TColorSwatch>;   { lbColorSwatches.Items, index-parallel - not every
      TColorSwatch is listed (Log: Trace/Debug/Info are left out, see lvLogCustomDrawItem: only
      Warn/Error/Critical actually change anything, so showing the other three would just be a
      swatch that silently does nothing) }
    FMenuLoopActive: Boolean;   { True while any TMenuItem's dropdown (main menu
      or a TPopupMenu) is actually on screen - see WMEnterMenuLoop/WMExitMenuLoop
      and SyncTimelineMenuState's header comment: mutating a menu's Enabled/
      Caption/Checked while Windows is still displaying it does not repaint,
      leaving stale/garbled text until the menu closes and reopens. Tracked
      via raw Windows menu-loop messages, which only the VCL/Delphi build
      receives through this "message" binding - under FPC/LCL the flag
      simply stays False (its pre-existing, unguarded behaviour). }
    FMixBuffer: TBitmap;
    FMixAutoBuffer: TBitmap;   // offscreen buffer for pbMixAutoPaint, mirrors FMixBuffer
    FFxName: string;
    FFxItem, FFxItems, FFxPer, FFxDone, FFxTotal: Integer;
    FFxLog: TMemo;
    FDspBuffer: TBitmap;       // offscreen buffer for pbSpectrumPaint, mirrors FMixBuffer
    FMixStripRects: array of TRect;    // last-painted strip hit-boxes, index-parallel to strip order
    FMixStripIds: array of Integer;
    FMixClipRects: array of TRect;     // combined L/R clip-LED hit-box, index-parallel to FMixClipIds
    FMixClipIds: array of Integer;
    FMixInsertDotRects: array of TRect;  // one per painted insert dot, this-tick only
    FMixInsertDotStripId: array of Integer;
    FMixInsertDotIndex: array of Integer;
    FMixZoomFactor: Double;            // tbMixZoom-driven strip-width scale, persisted (CFG_UI_MIXER_STRIP_WIDTH)
    FMixDragMode: TMixDragMode;
    FMixDragStripId: Integer;
    FMixDragInsertIndex: Integer;
    FMixAutoParam: TAutomationParam;
    FMixAutoTarget: Integer;
    FMixAutoSub: Integer;
    FMixAutoParams: array of TAutomationParam;
    FMixAutoTargets: array of Integer;
    FMixAutoSubs: array of Integer;
    FRec: TRecordingEngine;
    FRecWriter: TRecordingWriterThread;
    FRecRing: TAudioRing;
    FRecTrackId: Integer;
    { cboSetInDevice.Items[i] <-> FInputDeviceIds[i]; index 0 is always the
      "Default (system)" entry, mapped to '' (backend default endpoint). }
    FInputDeviceIds: TArray<string>;
    FRecInsertSeconds: Double;
    FRecCommitted: Boolean;
    FRecStarted: UInt64;
    FRecovery2: TRecordingRecovery;
    FRecBuffer: TBitmap;              // offscreen buffer for pbRecTakesPaint, mirrors FTlBuffer/FMixBuffer
    FRecTakeRects: TArray<TRect>;     // hit-test rects, index-parallel with FRecTakeIds
    FRecTakeIds: TArray<string>;      // TRecordedTake.Id (a session-folder string, not an integer)
    FRecSelectedTakeId: string;       // '' = no take selected
    FCompLane: TTakeLane;             // lane mirroring FRec's takes, for swipe-comping
    FComp: TTakeComp;
    FCompTakeCount: Integer;
    FRecSpan: Double;                 // seconds across the takes paint box (last paint)
    FCompSwipeOn: Boolean;
    FCompSwipeTake, FCompSwipeX0, FCompSwipeX1: Integer;
    FMixPreview: string;
    FMixRefreshing: Boolean;
    FTrkSelRow: Integer;
    FTrkSelChn: Integer;
    FTrkPreview: string;
    FTrkRefreshing: Boolean;
    FTrkPatternBuffer, FTrkSequenceBuffer: TBitmap;
    FTrkLastPattern, FTrkLastRow, FTrkLastOrder, FTrkLastScroll: Integer;
    FTrkSeqScroll: Integer;    // first visible order step in the sequence strip
    FTrkGridRowScroll: Integer;       // manual pattern-grid row scroll (mouse wheel); -1 = auto-follow selection/playback
    FTrkGridChnScroll: Integer;       // first visible channel column in the pattern grid (sbTrkChn)
    FTrkGridLastFirstRow: Integer;    // firstRow actually painted last (pbTrackerPaint), for click hit-testing
    FTrkInstrIndex: Integer;          // 1-based selected instrument on the Instruments sub-tab; 0 = none
    FTrkInstrWaveBuffer: TBitmap;
    FTrkPlayer: TTrackerPlayer;
    FTrkPlaying: Boolean;
    FMidiClipIndex: Integer;
    FMidiTrackIndex: Integer;
    FMidiEngine: IAudioSource;         // TMidiPlaybackEngine held as an interface
    FMidiEngineRef: TMidiPlaybackEngine;
    FMidiRefreshing: Boolean;
    FMidiDragMode: (mdmMidiNone, mdmMidiMove, mdmMidiResizeStart, mdmMidiResizeEnd);
    FMidiDragNoteId: Integer;
    FMidiDragStartX, FMidiDragStartY: Integer;   // pixel anchor at mouse-down
    FMidiDragAppliedTick: Int64;                 // total delta already sent to the command this drag
    FMidiDragAppliedNote: Integer;
    FMidiSelectedNoteId: Integer;
    FMidiScaleHighlight: Boolean;
    FMidiRangeDragging: Boolean;          { Ctrl+left-drag highlights a tick range }
    FMidiRangeActive: Boolean;
    FMidiRangeAnchor, FMidiRangeStart, FMidiRangeEnd: Int64;
    FMidiScaleRoot: Integer;    // 0=C .. 11=B
    FMidiScaleType: Integer;    // index into MIDI_SCALES (see NoteInScale)
    { Phase 38 - MIDI device I/O: real hardware input/output (Settings tab
      pickers persist by device NAME, not driver index - see
      RefreshMidiDeviceCombos/SaveSettingsTab - because a driver index is not
      stable across replug/reboot), live capture from the input device into
      the Timeline (see MidiRecArmClick/StopMidiRecording), and an internal
      synth used both for live-Thru monitoring while recording (mixed into
      Timeline playback - see TTimelinePlayer.AttachLiveMidiMonitor) and for
      the "MIDI panic" button. }
    FMidiInDevice: TMidiInputDevice;
    FMidiOutDevice: TMidiOutputDevice;
    FMidiInDeviceIds: TArray<string>;   // cboSetMidiInDevice.Items[i] <-> device name, '' = none
    FMidiOutDeviceIds: TArray<string>;  // cboSetMidiOutDevice.Items[i] <-> device name, '' = none
    FMidiMonitorSynth: TMidiSynth;
    FMidiCapture: TMidiCaptureEngine;
    FMidiRecording: Boolean;
    FMidiRecStartTick: UInt64;          // capture Start's position on FMidiInDevice's own clock (see TMidiInputDevice.OpenTickCount64) - NOT wall-clock GetTickCount64
    FMidiRecTrackId: Integer;
    FScopeSpectrum: TSpectrumAnalyzer;
    FScopeSpectrogram: TSpectrogramBuffer;
    FScopeGonio: TGoniometer;
    FScopeCapture: TOscilloscopeCapture;
    FScopeBallL, FScopeBallR: TBallisticMeter;
    FScopeSpecDb: array of Double;
    FScopeNyquist: Double;
    FScopeSnapshot: array of Single;
    FScopeSnapshotCount: Integer;
    FScopeReadout: string;
    FAiMcpServers: TStringList;       // display strings, index-aligned with MCPServerRegistry
    FAiHistory: TArray<TAIMessage>;    // Phases 21-22: running chat turns for the active provider
    FMcpBridge: TMCPToolBridge;        // Phase 26: connects to registry servers, feeds their tools into chat
    FMcpServer: TUDAWMcpServer;        // Phase 26: optional loopback MCP server exposing this DAW's tools
    {$IFNDEF FPC}
    FKeyHooks: TKeyHookManager;         // global (system-wide) hotkeys - see UDAW.Input.KeyHooks
    FKeyHookCaptureRow: Integer;        // >=0 while btnKeyHookAssign is waiting on the next keystroke
    procedure WMEnterMenuLoop(var Msg: TMessage); message WM_ENTERMENULOOP;
    procedure WMExitMenuLoop(var Msg: TMessage); message WM_EXITMENULOOP;
    procedure WMHotKey(var Msg: TMessage); message WM_HOTKEY;
    procedure ApplyKeyHooksOnStartup;
    procedure DoEmergencyStop;
    procedure DoToggleTimelinePlayback;
    procedure DoPanicStopAudio;
    procedure DoToggleMasterMute;
    {$ENDIF}
    procedure RunMcpDiagnostic(const AUrl: string);
    function McpServerGetDoc: TProjectDocument;
    function McpServerGetCommands: TCommandManager;
    function McpServerTransport(const AAction: string; AFromBeginning: Boolean): string;
    procedure RefreshMp4Tab;
    procedure RefreshMidiTab;
    function CurrentMidiSeq: TMidiSequence;
    procedure StopLiveRecording;
    function RecordingPosition: Double;
    function RecordingRootPath: string;
    procedure RefreshRecordingTab;
    procedure EnsureMixerStripsForTimelineTracks;
    procedure RefreshMixerTab;
    procedure RefreshTrackerTab(AFull: Boolean = True);
    function SelectedTrackerPattern: Integer;
    function SelectedMixStripId: Integer;
    function ExtractSidechainParam(var AParams: string): Integer;
    function BuildRecordSettings: TRecordSettings;
    procedure RefreshTimelineTab(AFull: Boolean = True);
    procedure SyncTimelineMenuState;
    procedure SyncTimelineScrollbar;
    procedure PopulateTimelineHistoryMenu(AParent: TMenuItem);
    procedure TlHistoryItemClick(Sender: TObject);
    function TimelineGrid: TGridContext;
    function TlLaneWidth: Integer;
    function TlTrackTop(AIndex: Integer): Integer;
    function TlTracksContentHeight: Integer;
    function TlMaxVScroll: Integer;
    function TlExtraTrackIndex(AId: Integer): Integer;
    function TlRangeTrackIds: TArray<Integer>;
    procedure TlExtraTrackRemove(AId: Integer);
    function TlTrackAtY(AY: Integer; out ATrackIndex: Integer): Boolean;
    function TlMuteButtonRect(ATop: Integer): TRect;
    function TlTempoUnknownRect(ATop, ALaneH: Integer): TRect;
    function TlPrimaryTempoUnknown(ATrack: TTimelineTrack): Boolean;
    procedure ApplyBaselineTempoOnImport(AClipId: Integer);
    procedure TlTempoUnknownClick;
    function TlTrackTitleRect(ATop, AWidth: Integer): TRect;
    procedure TlNoteEffectAdded(AStripId: Integer; const AEffectName: string);
    function TlEffectColor(const AEffectName: string): TColor;
    function TlClipRegions(AClip: TTimelineClip): TArray<TClipEffectRegion>;
    function TlClipAtPoint(AX, AY: Integer): TTimelineClip;
    function TlHitTestClipEdge(AClip: TTimelineClip; AX: Integer; out AEdge: TClipEdge): Boolean;
    function TlHitTestFadeHandle(AClip: TTimelineClip; ATrackIndex, AX, AY: Integer;
      out AEdge: TClipEdge): Boolean;
    function TlIsClipSelected(AClipId: Integer): Boolean;
    function TlTrackHasSelectedClip(ATrack: TTimelineTrack): Boolean;
    procedure TlSetSingleSelection(AClipId: Integer);
    procedure TlToggleSelection(AClipId: Integer);
    function TlDuplicateSelectedClips: TArray<Integer>;
    procedure TlSelectRubberBand;
    procedure TlSplitAtRangeEdges;
    procedure TlApplyEffectToRange(const AKind, AParams, AEffectName: string);
    procedure TlSplitStemsSelected;
    procedure TlAudioToMidiSelected;
    procedure TlApplySilenceToRange;
    procedure TlUndoEffectInRange;
    function TlHealMissingEffectSources: Boolean;
    function MidiRowHeight: Integer;
    function MidiNoteAtY(AY: Integer): Integer;
    function MidiTickAtX(AX: Integer): Int64;
    function MidiFindNoteAt(AX, AY: Integer; out ATrk: TMidiTrackSeq; out ANote: TMidiNote): Boolean;
    function MidiHitTestNoteEdge(const ANote: TMidiNote; AX: Integer): Integer; // -1 none, 0 start, 1 end
    function MidiNoteInScale(ANote: Integer): Boolean;
    procedure PopulateBrowserRoots;
    procedure BrowserAddRoot(const APath: string);
    function BrowserNodePath(ANode: TTreeNode): string;
    procedure BrowserExpandNode(ANode: TTreeNode);
    function BrowserIsAudioExt(const AExt: string): Boolean;
    function ImportBrowserFileToTimeline(const APath: string; ATrackId: Integer;
      AStartSeconds: Double): Boolean;
    function GetAiBrowserRoots: TArray<string>;
    function ProbeVst2File(const APath: string; out AParamCount: Integer;
      out AError: string): Boolean;
    function MixStripHasVst2Insert(AStrip: TMixStrip; const APathB64: string): Boolean;
    procedure BuildDemoArrangement;
    function TlFirstAudioTrackId: Integer;
    function TlSelectedAudioTrackId: Integer;
    function TlNewAudioTrackId: Integer;
    function TlNewVideoTrackId: Integer;
    function TlHasVideo: Boolean;
    function ExecuteTimelineExportDialog(AFilterIndex: Integer; out ADest: string): Boolean;
    function TlTrackIndexById(ATrackId: Integer): Integer;
    function TlDropTargetTrackId(AX, AY: Integer): Integer;
    { Registration gate: returns True when registered. Otherwise tells the user
      AFeature is unavailable in the unregistered edition, jumps to the
      Registration tab and returns False. Exporting of any kind and any use of AI
      call this first. }
    function RequireRegistration(const AFeature: string): Boolean;
    procedure UpdateRegistrationUI;
    { staged effect progress: FxBegin(name, items, stages-per-item) then per item
      FxItem(no) / FxStage / FxStageDone, finally FxEnd. Status bar shows
      "effect - item i/n - stage k/m: what (pct)  [overall d/t stages]" and each
      completed stage is logged to the given memo. }
    procedure FxBegin(const AName: string; AItems, AStagesPerItem: Integer; ALog: TMemo);
    procedure FxItem(ANo: Integer);
    procedure FxStage(AStageNo: Integer; const AWhat: string; APct: Integer);
    procedure FxStageDone(AStageNo: Integer; const AWhat: string);
    procedure FxEnd;
    procedure ShowStatusProgress(const AText: string; AMax: Integer = 100);
    procedure ShowStatusBusy(const AText: string);
    procedure UpdateStatusProgress(AValue: Integer; const AText: string = '');
    procedure HideStatusProgress;
    procedure ImportTrackerModuleToTimeline(AModule: TTrackerModule;
      const ASourceFileName, AKindLabel: string);
    procedure TrkImportRenderProgress(Sender: TObject; AFraction: Double);
    procedure NormalizeTrackerRender(var APlanar: TAudioPlanar; AFrameCount: Integer);
    procedure WarmClipWaveform(ASourceId: Integer; AProgressBase: Integer = 0;
      AProgressSpan: Integer = 100; AShowProgress: Boolean = True);
    procedure RefreshSystemTab;
    procedure LoadSettingsTab;
    procedure InstallControlHints;
    function ProjectFingerprint: string;
    function ProjectSecretKey: string;
    procedure RefreshInputDeviceCombo(const ASelectedDeviceId: string);
    procedure RefreshMidiDeviceCombos(const ASelectedInName, ASelectedOutName: string);
    procedure OpenMidiDevicesFromConfig;
    procedure HandleLiveMidiInput(Sender: TObject; const AMsg: TMidiMessage; ATimestampMs: Cardinal);
    procedure LoadColorsTab;
    procedure LoadKeyHooksTab;
    procedure SaveSettingsTab;
    procedure ApplyDirDialogs;
    procedure PumpLog;
    procedure RefreshJobs;
    procedure RefreshAudio;
    procedure RunDspAnalysis;
    procedure RunScopeAnalysis;
    procedure RunAdvDspProcess;
    procedure RefreshAiTab;
    procedure BuildGraphPreset;
    procedure RunGraphAnalysis;
    procedure OpenInShell(const APath: string);
    procedure RefreshProjectTab;
    procedure ProjectTick;
    function SelectedWavFormat: TWavSampleFormat;
    function Mp3TabTone(AFreqL, AFreqR: Double; AFrames: Integer): TAudioPlanar;
    procedure OpenProjectFile(const AFileName: string; AAsRecovery: Boolean);
    procedure ReportProjectError(const AWhat: string; E: Exception);
    procedure LogViewerFormClose(Sender: TObject; var Action: TCloseAction);
    procedure VST2EditorClosing(Sender: TObject);
    function OpenVST2EditorForInsert(AStripId, AIndex: Integer): Boolean;
    procedure CaptureOpenWindowLayout;
    procedure RestoreWindowLayout;
  end;

var
  frmMain: TfrmMain;

implementation

{$IFDEF FPC}
{$R *.lfm}
{$ELSE}
{$R *.dfm}
{$ENDIF}

uses
  UDAW.Platform;

{ Themed one-field prompt with the edit box BELOW the (wrapped) prompt text,
  unlike InputQuery, which puts a long prompt and its edit side by side. }
function PromptValueBelow(const ACaption, APrompt: string; var AValue: string): Boolean;
var
  f: TForm;
  lbl: TLabel;
  ed: TEdit;
  ok, cancel: TButton;
begin
  f := TForm.CreateNew(Application);
  try
    f.Caption := ACaption;
    f.BorderStyle := bsDialog;
    f.Position := poOwnerFormCenter;
    f.ClientWidth := 520;
    lbl := TLabel.Create(f);
    lbl.Parent := f;
    lbl.WordWrap := True;
    lbl.AutoSize := False;
    lbl.SetBounds(16, 16, f.ClientWidth - 32, 64);
    lbl.Caption := APrompt;
    ed := TEdit.Create(f);
    ed.Parent := f;
    ed.SetBounds(16, lbl.Top + lbl.Height + 8, f.ClientWidth - 32, ed.Height);
    ed.Text := AValue;
    ok := TButton.Create(f);
    ok.Parent := f;
    ok.Caption := 'OK';
    ok.Default := True;
    ok.ModalResult := mrOk;
    ok.SetBounds(f.ClientWidth - 16 - 75 * 2 - 8, ed.Top + ed.Height + 16, 75, 25);
    cancel := TButton.Create(f);
    cancel.Parent := f;
    cancel.Caption := 'Cancel';
    cancel.Cancel := True;
    cancel.ModalResult := mrCancel;
    cancel.SetBounds(f.ClientWidth - 16 - 75, ok.Top, 75, 25);
    f.ClientHeight := ok.Top + ok.Height + 16;
    f.ActiveControl := ed;
    ed.SelectAll;
    Result := f.ShowModal = mrOk;
    if Result then AValue := ed.Text;
  finally
    f.Free;
  end;
end;

{ ---- a real self-test job (exercises the framework end to end) ---- }

type
  TSelfTestJob = class(TJob)
  protected
    function Execute: Boolean; override;
  end;

function TSelfTestJob.Execute: Boolean;
var
  s: string;
begin
  SetProgress(0.10, 'logger flush');
  Logger.Info('selftest', 'self-test job started');
  if not Logger.Flush(2000) then
    raise Exception.Create('logger did not flush');

  SetProgress(0.35, 'config');
  App.Config.SetString('selftest', 'stamp', DateTimeToStr(Now));
  if not App.Config.Save then
    raise Exception.Create('config save failed');

  SetProgress(0.60, 'secure storage');
  if (App.Secure <> nil) and App.Secure.IsAvailable then
  begin
    App.Secure.SetSecret('udaw.ui.selftest', 'roundtrip-value');
    try
      if not App.Secure.GetSecret('udaw.ui.selftest', s) then
        raise Exception.Create('secret not found after write');
      if s <> 'roundtrip-value' then
        raise Exception.Create('secret did not roundtrip');
    finally
      App.Secure.DeleteSecret('udaw.ui.selftest');
    end;
  end;

  SetProgress(0.85, 'jobs');
  Sleep(150);

  Logger.Info('selftest', 'self-test job finished OK');
  Result := True;
end;

{ ---- TfrmMain ---- }

procedure TfrmMain.FormCreate(Sender: TObject);
var
  i: Integer;
begin
  FTlRubberBandMods := [ssShift];
  Caption := Format('UDAW - by Ultimanium Designs (C) 2026 - %s', [UDAWDisplayVersionString]);
  lblHeader.Caption := 'Ultimanium Audio Studio  -  system diagnostics (platform, audio engine, graph, project, PCM/WAV, timeline, recording)';
  {$IFNDEF FPC}
  edtRegUsername.Text := TUDAWLicense.CachedUsername;
  edtRegSerial.Text := TUDAWLicense.CachedSerial;
  lblRegVersion.Caption := 'Installed version: ' + UDAWNumericVersion;
  TUDAWLicense.OnStateChanged :=
    procedure
    begin
      UpdateRegistrationUI;
    end;
  UpdateRegistrationUI;
  {$ENDIF}
  FTrackedJobs := TList.Create;
  FTrkPatternBuffer := TBitmap.Create;
  FTrkSequenceBuffer := TBitmap.Create;
  FTrkInstrWaveBuffer := TBitmap.Create;
  pbTracker.ControlStyle := pbTracker.ControlStyle + [csOpaque];
  pbTrkSequence.ControlStyle := pbTrkSequence.ControlStyle + [csOpaque];
  pbTrkInstrWave.ControlStyle := pbTrkInstrWave.ControlStyle + [csOpaque];
  FTlWaveformWarned := TStringList.Create;
  FTlWaveformWarned.Sorted := True;
  FTlWaveformWarned.Duplicates := dupIgnore;
  FTlDragStartTrackIdx := -1;

  {$IFNDEF FPC}
  { OS Explorer file drag-in - see WMDropFiles. Registered on the form's own
    handle, not pbTimeline's (a windowless TGraphicControl can't hold one). }
  DragAcceptFiles(Handle, True);
  {$ENDIF}

  { restore the window size (and maximized state) recorded on the last resize }
  if (App <> nil) and (App.Config <> nil) then
  begin
    SetBounds(Left, Top,
      EnsureRange(App.Config.GetInt(CFG_SEC_UI, CFG_UI_WIDTH, Width), 400, Max(400, Screen.WorkAreaWidth)),
      EnsureRange(App.Config.GetInt(CFG_SEC_UI, CFG_UI_HEIGHT, Height), 300, Max(300, Screen.WorkAreaHeight)));
    if App.Config.GetBool(CFG_SEC_UI, CFG_UI_MAXIMIZED, False) then WindowState := wsMaximized;
  end;
  FWindowStateReady := True;

  cboLevel.Items.Clear;
  cboLevel.Items.Add('trace');
  cboLevel.Items.Add('debug');
  cboLevel.Items.Add('info');
  cboLevel.Items.Add('warn');
  cboLevel.Items.Add('error');
  cboLevel.Items.Add('critical');
  cboLevel.ItemIndex := cboLevel.Items.IndexOf(LowerCase(LevelName(Logger.MinLevel)));
  if cboLevel.ItemIndex < 0 then
    cboLevel.ItemIndex := 2;

  cboDspSignal.Items.Clear;
  cboDspSignal.Items.Add('Sine 440 Hz');
  cboDspSignal.Items.Add('Sine 1 kHz');
  cboDspSignal.Items.Add('Sweep 20 Hz - 20 kHz');
  cboDspSignal.Items.Add('White noise');
  cboDspSignal.Items.Add('Pink noise');
  cboDspSignal.Items.Add('Project mix (current timeline)');
  cboDspSignal.ItemIndex := 1;

  cboDspFilter.Items.Clear;
  cboDspFilter.Items.Add('Bypass');
  cboDspFilter.Items.Add('Lowpass 1 kHz (Q 0.707)');
  cboDspFilter.Items.Add('Highpass 200 Hz (Q 0.707)');
  cboDspFilter.Items.Add('Peaking +6 dB @ 2 kHz (Q 2)');
  cboDspFilter.Items.Add('Notch 1 kHz (Q 8)');
  cboDspFilter.Items.Add('Butterworth LP 500 Hz (4th order)');
  cboDspFilter.ItemIndex := 1;

  cboDspWindow.Items.Clear;
  cboDspWindow.Items.Add('Rectangular');
  cboDspWindow.Items.Add('Hann');
  cboDspWindow.Items.Add('Hamming');
  cboDspWindow.Items.Add('Blackman');
  cboDspWindow.Items.Add('Blackman-Harris');
  cboDspWindow.ItemIndex := 1;

  cboGraphPreset.Items.Clear;
  cboGraphPreset.Items.Add('Sine 440 Hz  ->  Gain -6 dB  ->  Output');
  cboGraphPreset.Items.Add('Saw 220 Hz  ->  Lowpass 1.2 kHz  ->  Meter  ->  Output');
  cboGraphPreset.Items.Add('Sines 220 + 660 Hz  ->  Bus  ->  Gain -3 dB  ->  Output');
  cboGraphPreset.Items.Add('Sine 1 kHz  ->  Delay 250 ms (fb 0.35)  ->  Output');
  cboGraphPreset.Items.Add('Pink noise  ->  Highpass 300 Hz  ->  Pan left  ->  Meter  ->  Output');
  cboGraphPreset.ItemIndex := 1;

  cboProjectSampleRate.Items.Clear;
  cboProjectSampleRate.Items.Add('22050');
  cboProjectSampleRate.Items.Add('32000');
  cboProjectSampleRate.Items.Add('44100');
  cboProjectSampleRate.Items.Add('48000');
  cboProjectSampleRate.Items.Add('88200');
  cboProjectSampleRate.Items.Add('96000');
  cboProjectSampleRate.Items.Add('176400');
  cboProjectSampleRate.Items.Add('192000');

  cboAutosaveInterval.Items.Clear;
  cboAutosaveInterval.Items.Add(AutosaveIntervalName(aiOff));
  cboAutosaveInterval.Items.Add(AutosaveIntervalName(ai1Min));
  cboAutosaveInterval.Items.Add(AutosaveIntervalName(ai2Min));
  cboAutosaveInterval.Items.Add(AutosaveIntervalName(ai5Min));
  cboAutosaveInterval.Items.Add(AutosaveIntervalName(ai10Min));
  cboAutosaveInterval.ItemIndex := Ord(ai5Min);

  cboWavFormat.Items.Clear;
  cboWavFormat.Items.Add('PCM 8-bit');
  cboWavFormat.Items.Add('PCM 16-bit');
  cboWavFormat.Items.Add('PCM 24-bit');
  cboWavFormat.Items.Add('PCM 32-bit');
  cboWavFormat.Items.Add('IEEE float 32-bit');
  cboWavFormat.Items.Add('IEEE float 64-bit');
  cboWavFormat.ItemIndex := 1;
  mnuWavPlay.Enabled := False;
  pmWavPlay.Enabled := False;

  cboMp3Bitrate.Items.Clear;
  cboMp3Bitrate.Items.Add('128');
  cboMp3Bitrate.Items.Add('160');
  cboMp3Bitrate.Items.Add('192');
  cboMp3Bitrate.Items.Add('256');
  cboMp3Bitrate.Items.Add('320');
  cboMp3Bitrate.ItemIndex := 2;

  cboMp4Fmt.Items.Clear;
  cboMp4Fmt.Items.Add('PCM 16-bit');
  cboMp4Fmt.Items.Add('PCM 24-bit');
  cboMp4Fmt.Items.Add('Float 32-bit');
  cboMp4Fmt.ItemIndex := 0;

  cboMidiGrid.Items.Clear;
  cboMidiGrid.Items.Add('1/4');
  cboMidiGrid.Items.Add('1/8');
  cboMidiGrid.Items.Add('1/16');
  cboMidiGrid.Items.Add('1/32');
  cboMidiGrid.ItemIndex := 2;
  FMidiClipIndex := -1;
  FMidiTrackIndex := 0;
  FMidiSelectedNoteId := -1;
  FMidiDragMode := mdmMidiNone;
  cboMidiScaleRoot.Items.CommaText := 'C,C#,D,D#,E,F,F#,G,G#,A,A#,B';
  cboMidiScaleRoot.ItemIndex := 0;
  cboMidiScaleType.Items.CommaText := 'Major,Natural minor,Major pentatonic,Minor pentatonic';
  cboMidiScaleType.ItemIndex := 0;
  FMidiScaleRoot := 0;
  FMidiScaleType := 0;
  FMidiScaleHighlight := False;

  cboTlSnap.Items.Clear;
  cboTlSnap.Items.Add(SnapModeDisplay(smOff));
  cboTlSnap.Items.Add(SnapModeDisplay(smBar));
  cboTlSnap.Items.Add(SnapModeDisplay(smBeat));
  cboTlSnap.Items.Add(SnapModeDisplay(smDiv2));
  cboTlSnap.Items.Add(SnapModeDisplay(smDiv4));
  cboTlSnap.Items.Add(SnapModeDisplay(smDiv8));
  cboTlSnap.Items.Add(SnapModeDisplay(smDiv16));
  cboTlSnap.Items.Add(SnapModeDisplay(smSecond));
  cboTlSnap.Items.Add(SnapModeDisplay(smSample));   // "Realtime" - see SNAP_DISPLAY
  cboTlSnap.ItemIndex := 8;   // Realtime (smSample) - the user's requested default: free/unquantized positioning

  FTlView := TTimelineView.Create;
  FTlView.SetHeaderWidth(150);
  FTlView.SetRulerHeight(26);
  FTlView.SetTrackTitleHeight(14);
  FTlView.SnapMode := smSample;
  FTlSelClipId := -1;
  FTlCtxTrackId := -1;
  FTlSelectedTrackId := -1;
  FTlHaveSelectionClipboard := False;
  FRecInsertSeconds := 0;
  FTlBuffer := TBitmap.Create;
  FTlMeterBuffer := TBitmap.Create;
  FTlSpectrum := TSpectrumAnalyzer.Create;
  SetLength(FTlSpecTap, 2048);
  FMixBuffer := TBitmap.Create;
  FMixAutoBuffer := TBitmap.Create;
  FRecBuffer := TBitmap.Create;
  FRecSelectedTakeId := '';
  FDspBuffer := TBitmap.Create;
  FTlTrimClipId := -1;
  FTlFadeClipId := -1;
  { pbTimeline is already fully double-buffered (paint goes into FTlBuffer,
    one Draw blits it) - csOpaque tells the VCL/LCL paint machinery this
    control always fills its own client area, so it skips erasing the
    background (WM_ERASEBKGND) before OnPaint fires. Without it, a resize
    still shows a brief flash of the parent panel's colour under the new
    area before the buffered paint catches up. }
  pbTimeline.ControlStyle := pbTimeline.ControlStyle + [csOpaque];
  { pbTlMeters (Timeline Out L/R graphs) is buffered the same way - see
    FTlMeterL/FTlMeterR's declaration comment. }
  pbTlMeters.ControlStyle := pbTlMeters.ControlStyle + [csOpaque];
  { same reasoning as pbTimeline above - both mixer paint boxes are fully
    buffered (FMixBuffer / FMixAutoBuffer), so csOpaque skips the
    WM_ERASEBKGND flash on resize/tab-switch. }
  pbMixer.ControlStyle := pbMixer.ControlStyle + [csOpaque];
  pbMixAuto.ControlStyle := pbMixAuto.ControlStyle + [csOpaque];
  { same reasoning again: pbRecTakes now paints into FRecBuffer and blits it
    in one shot (see pbRecTakesPaint) instead of drawing every take rectangle
    straight to the screen DC every tick tmrUI invalidates it during
    recording. }
  pbRecTakes.ControlStyle := pbRecTakes.ControlStyle + [csOpaque];
  { pbSpectrum paints into FDspBuffer (see pbSpectrumPaint) - it is
    invalidated every tmrUI tick while "Live" is checked on the DSP tab
    (RunDspAnalysis), which flickered badly without buffering. }
  pbSpectrum.ControlStyle := pbSpectrum.ControlStyle + [csOpaque];

  FProject := TProjectDocument.CreateNew;
  FCmds := TCommandManager.Create;
  FRecovery := TProjectRecoveryManager.Create;
  FRecovery.Interval := ai5Min;
  FOpenVST2Editors := TList<TfrmVST2Editor>.Create;

  cboRecChannels.Items.Clear;
  cboRecChannels.Items.Add('Mono');
  cboRecChannels.Items.Add('Stereo');
  cboRecChannels.Items.Add('4-channel');
  cboRecChannels.ItemIndex := 1;
  cboRecFormat.Items.Clear;
  cboRecFormat.Items.Add('IEEE float 32-bit');
  cboRecFormat.Items.Add('PCM 24-bit');
  cboRecFormat.Items.Add('PCM 16-bit');
  cboRecFormat.ItemIndex := 0;
  cboRecPunch.Items.Clear;
  cboRecPunch.Items.Add('Off');
  cboRecPunch.Items.Add('Punch-in');
  cboRecPunch.Items.Add('Punch in/out');
  cboRecPunch.ItemIndex := 0;
  cboRecPunchChange(nil);
  chkRecLoopClick(nil);
  if App <> nil then
    FRec := TRecordingEngine.Create(
      RecordingRootPath)
  else
    FRec := TRecordingEngine.Create(GetCurrentDir + PathDelim + 'recordings');
  if App <> nil then
    FRecovery2 := TRecordingRecovery.Create(
      RecordingRootPath);
  cboRecPunchChange(nil);
  chkRecLoopClick(nil);

  {$IFNDEF FPC}
  FKeyHookCaptureRow := -1;
  FKeyHooks := TKeyHookManager.Create(Handle);
  ApplyKeyHooksOnStartup;
  {$ENDIF}

  FDspReadout := '(press Analyze)';

  if (App <> nil) and (App.Secure <> nil) then
    lblSecureProvider.Caption := Format('Provider: %s  (available: %s)',
      [App.Secure.ProviderName, BoolToStr(App.Secure.IsAvailable, True)])
  else
    lblSecureProvider.Caption := 'Provider: (none)';

  FMixPreview := '(press Render preview mix)';
  cboMixInsertKind.Items.Clear;
  cboMixInsertKind.Items.Add('Trim gain (+6 dB)');
  cboMixInsertKind.Items.Add('Parametric EQ (6-band)');
  cboMixInsertKind.Items.Add('Graphic EQ (10-band flat)');
  cboMixInsertKind.Items.Add('Compressor');
  cboMixInsertKind.Items.Add('Limiter (lookahead brickwall)');
  cboMixInsertKind.Items.Add('Noise gate');
  cboMixInsertKind.Items.Add('Expander');
  cboMixInsertKind.Items.Add('De-esser');
  cboMixInsertKind.Items.Add('Chorus');
  cboMixInsertKind.Items.Add('Flanger');
  cboMixInsertKind.Items.Add('Phaser');
  cboMixInsertKind.Items.Add('Tremolo');
  cboMixInsertKind.Items.Add('Auto-Pan');
  cboMixInsertKind.Items.Add('Saturation');
  cboMixInsertKind.Items.Add('Hard Clip');
  cboMixInsertKind.Items.Add('Foldback');
  cboMixInsertKind.Items.Add('Bit Crusher');
  cboMixInsertKind.Items.Add('Reverb');
  cboMixInsertKind.Items.Add('Delay');
  cboMixInsertKind.Items.Add('Delay (ping-pong)');
  cboMixInsertKind.Items.Add('Stereo Width');
  cboMixInsertKind.Items.Add('Transient Shaper');
  cboMixInsertKind.Items.Add('Exciter');
  cboMixInsertKind.Items.Add('Pitch Shift');
  cboMixInsertKind.Items.Add('Multiband Compressor');
  cboMixInsertKind.Items.Add('Mastering Chain');
  cboMixInsertKind.ItemIndex := 3;

  cboMixAutoParam.Items.Add('Fader');
  cboMixAutoParam.Items.Add('Pan');
  cboMixAutoParam.ItemIndex := 0;
  FMixAutoParam := apFader;
  FMixAutoTarget := 0;
  FMixAutoSub := 0;
  cboMixAutoMode.Items.Add('Off');
  cboMixAutoMode.Items.Add('Read');
  cboMixAutoMode.Items.Add('Touch');
  cboMixAutoMode.Items.Add('Latch');
  cboMixAutoMode.Items.Add('Write');
  cboMixAutoMode.ItemIndex := 0;
  FMixZoomFactor := 1.0;
  if (App <> nil) and (App.Config <> nil) then
  begin
    FMixZoomFactor := EnsureRange(
      App.Config.GetFloat(CFG_SEC_UI, CFG_UI_MIXER_STRIP_WIDTH, 1.0), 0.5, 2.0);
    tbMixZoom.Position := Round(FMixZoomFactor * 10.0);
  end;

  FTrkSelRow := 0;
  FTrkSelChn := 0;
  FTrkGridRowScroll := -1;
  FTrkGridChnScroll := 0;
  FTrkGridLastFirstRow := 0;
  FTrkInstrIndex := 1;
  FTrkPreview := '(press Play pattern)';

  cboScopeSignal.Items.Clear;
  cboScopeSignal.Items.Add('Sine 440 Hz');
  cboScopeSignal.Items.Add('Sine 1 kHz');
  cboScopeSignal.Items.Add('Sweep 20 Hz - 20 kHz');
  cboScopeSignal.Items.Add('White noise');
  cboScopeSignal.Items.Add('Pink noise');
  cboScopeSignal.Items.Add('Project Mix (Timeline)');
  cboScopeSignal.ItemIndex := 1;

  cboScopeMode.Items.Clear;
  cboScopeMode.Items.Add('Spectrum');
  cboScopeMode.Items.Add('Spectrogram');
  cboScopeMode.Items.Add('Goniometer');
  cboScopeMode.Items.Add('Oscilloscope');
  cboScopeMode.Items.Add('Meters');
  cboScopeMode.ItemIndex := 0;

  FScopeSpectrum := TSpectrumAnalyzer.Create;
  FScopeSpectrogram := TSpectrogramBuffer.Create;
  FScopeGonio := TGoniometer.Create;
  FScopeCapture := TOscilloscopeCapture.Create;
  FScopeReadout := '(press Analyze)';

  cboAdvDspSignal.Items.Assign(cboScopeSignal.Items);
  cboAdvDspSignal.ItemIndex := 1;

  cboAdvDspProcess.Items.Clear;
  cboAdvDspProcess.Items.Add('Multiband compressor (low band squashed)');
  cboAdvDspProcess.Items.Add('Mastering chain (-1 dBTP ceiling, -14 LUFS)');
  cboAdvDspProcess.Items.Add('Time stretch');
  cboAdvDspProcess.Items.Add('Pitch shift (semitones)');
  cboAdvDspProcess.ItemIndex := 0;
  memAdvDspReadout.Lines.Text := '(press Run)';

  cboAiProvider.Items.Clear;
  for i := 0 to High(AI_KNOWN_PROVIDERS) do
    cboAiProvider.Items.Add(AIProviderDisplayName(AI_KNOWN_PROVIDERS[i]));
  { Suno is the AI Selection tab's default system (music generation), not a
    chat provider - see the header comment above cboAiProviderChange. }
  cboAiProvider.ItemIndex := IndexStr('suno', AI_KNOWN_PROVIDERS);
  FAiMcpServers := TStringList.Create;
  FSunoRefs := TStringList.Create;
  FMcpBridge := TMCPToolBridge.Create;

  RefreshSystemTab;
  PumpLog;
  RefreshAudio;
  RefreshProjectTab;
  RefreshMixerTab;
  RefreshTrackerTab;
  RefreshMp4Tab;
  RefreshMidiTab;
  FMidiMonitorSynth := TMidiSynth.Create;
  FMidiCapture := TMidiCaptureEngine.Create;
  FMidiCapture.Monitor := FMidiMonitorSynth;
  FMidiInDevice := TMidiInputDevice.Create;
  FMidiOutDevice := TMidiOutputDevice.Create;
  OpenMidiDevicesFromConfig;
  LoadSettingsTab;
  InstallControlHints;
  RefreshAiTab;
  PopulateBrowserRoots;
  RestoreStartupProject;
  pgc.ActivePage := tabProject;
  pgcChange(pgc);
end;

{ Only one tab's menu is ever visible on mnuMain at a time - each tab's action
  buttons live in its own top-level menu (Tracker, Mixer, ...); this shows
  whichever one matches the active page and hides the rest, so the menu bar
  never grows past one contextual menu regardless of how many tabs exist. }
function TfrmMain.ActiveWorkspacePage: TTabSheet;
begin
  Result := pgc.ActivePage;
  if Result = tabSettings then
  begin
    Result := pgcSettings.ActivePage;
    if Result = tabSettingsDiagnostics then Result := pgcDiagnostics.ActivePage;
  end;
end;

procedure TfrmMain.pgcChange(Sender: TObject);
begin
  mnuTracker.Visible := pgc.ActivePage = tabTracker;
  mnuMixer.Visible := pgc.ActivePage = tabMixer;
  mnuMidi.Visible := pgc.ActivePage = tabMIDI;
  mnuTimeline.Visible := pgc.ActivePage = tabTimeline;
  mnuProject.Visible := pgc.ActivePage = tabProject;
  mnuMp3.Visible := ActiveWorkspacePage = tabMP3;
  mnuSystem.Visible := ActiveWorkspacePage = tabSystem;
  mnuLog.Visible := True;
  mnuJobs.Visible := ActiveWorkspacePage = tabJobs;
  mnuAudio.Visible := ActiveWorkspacePage = tabAudio;
  mnuDsp.Visible := ActiveWorkspacePage = tabDSP;
  mnuGraph.Visible := ActiveWorkspacePage = tabGraph;
  mnuWav.Visible := ActiveWorkspacePage = tabWav;
  mnuRecording.Visible := pgc.ActivePage = tabRecording;
  mnuSecure.Visible := ActiveWorkspacePage = tabSecure;
  mnuMp4.Visible := ActiveWorkspacePage = tabMP4;
  mnuSettings.Visible := pgc.ActivePage = tabSettings;
  mnuScope.Visible := ActiveWorkspacePage = tabScope;
  mnuAdvDsp.Visible := ActiveWorkspacePage = tabAdvDsp;
  mnuAi.Visible := pgc.ActivePage = tabAI;

  if pgc.ActivePage = tabSettings then
    sbSettings.VertScrollBar.Position := 0;
end;

const
  WINKEY_LOGVIEWER = 'LogViewer';
  WINKEY_BROWSER   = 'BrowserWindow';
  WINKEY_VST2_PREFIX = 'VST2Editor:';
  { Not a window: Left = pixels-per-second * 1000, Top = scroll seconds * 1000
    (reuses the layout section so no project format change is needed). }
  WINKEY_TIMELINEVIEW = 'TimelineView';

function SavedWindowStateOf(AForm: TForm): TSavedWindowState;
begin
  case AForm.WindowState of
    wsMinimized: Result := swsMinimized;
    wsMaximized: Result := swsMaximized;
  else
    Result := swsNormal;
  end;
end;

procedure ApplySavedGeometry(AForm: TForm; AEntry: TWindowLayoutEntry);
begin
  if AEntry = nil then Exit;
  if (AEntry.Width > 0) and (AEntry.Height > 0) then
  begin
    { These forms are designed with Position = poOwnerFormCenter/poScreenCenter
      for their normal first-open UX, but that policy is applied when the
      form's window handle is created (i.e. on the .Show that follows this
      call), which silently overrides whatever bounds we set here - the
      restored window would always snap back to centered instead of its
      saved position. Switching to poDesigned before SetBounds is what makes
      a restored position/size actually stick. }
    AForm.Position := poDesigned;
    AForm.SetBounds(AEntry.Left, AEntry.Top, AEntry.Width, AEntry.Height);
    case AEntry.State of
      swsMinimized: AForm.WindowState := wsMinimized;
      swsMaximized: AForm.WindowState := wsMaximized;
    else
      AForm.WindowState := wsNormal;
    end;
  end;
end;

procedure TfrmMain.ShowLogClick(Sender: TObject);
begin
  if FLogViewer = nil then
  begin
    FLogViewer := TfrmLogViewer.Create(Self);
    FLogViewer.OnClose := LogViewerFormClose;
    pnlLogView.Parent := FLogViewer;
    pnlLogView.Align := alClient;
    pnlLogView.Visible := True;
    ApplySavedGeometry(FLogViewer, FProject.Windows.Find(WINKEY_LOGVIEWER));
  end;
  FLogViewer.Show;
  FLogViewer.BringToFront;
end;

procedure TfrmMain.LogViewerFormClose(Sender: TObject; var Action: TCloseAction);
begin
  { The user closing this window is an explicit "don't reopen it next time" -
    forget it rather than Put its geometry, or it would come back on every
    future project load even after being deliberately closed before exit.
    A window that is still open when the project is saved/closed is
    remembered separately, by CaptureOpenWindowLayout. }
  if FProject <> nil then
    FProject.Windows.Remove(WINKEY_LOGVIEWER);
  Action := caHide;   // the Log Viewer is a lazy singleton, kept alive for the session
end;

procedure TfrmMain.OpenBrowserWindowClick(Sender: TObject);
begin
  if FBrowserWindow = nil then
  begin
    FBrowserWindow := TfrmBrowserWindow.Create(Self);
    FBrowserWindow.OnClose := BrowserWindowFormClose;
    pnlBrowserTop.Parent := FBrowserWindow;
    pnlBrowserTop.Align := alTop;
    memBrowser.Parent := FBrowserWindow;
    memBrowser.Align := alBottom;
    tvBrowser.Parent := FBrowserWindow;
    tvBrowser.Align := alClient;
    lblBrowserFloating.Visible := True;
    ApplySavedGeometry(FBrowserWindow, FProject.Windows.Find(WINKEY_BROWSER));
  end;
  FBrowserWindow.Show;
  FBrowserWindow.BringToFront;
end;

procedure TfrmMain.BrowserWindowFormClose(Sender: TObject; var Action: TCloseAction);
begin
  { See LogViewerFormClose: the user closing this window means "don't reopen
    it next time", so forget it rather than remembering its final geometry.
    A window still open when the project is saved/closed is captured
    separately by CaptureOpenWindowLayout. }
  if FProject <> nil then
    FProject.Windows.Remove(WINKEY_BROWSER);
  pnlBrowserTop.Parent := tabBrowser;
  pnlBrowserTop.Align := alTop;
  memBrowser.Parent := tabBrowser;
  memBrowser.Align := alBottom;
  tvBrowser.Parent := tabBrowser;
  tvBrowser.Align := alClient;
  lblBrowserFloating.Visible := False;
  Action := caFree;
  FBrowserWindow := nil;
end;

procedure TfrmMain.CaptureOpenWindowLayout;
var
  i: Integer;
  frm: TfrmVST2Editor;
begin
  if FProject = nil then Exit;
  if FTlView <> nil then
    FProject.Windows.Put(WINKEY_TIMELINEVIEW, Round(FTlView.PixelsPerSecond * 1000),
      Round(FTlView.ScrollSeconds * 1000), 0, 0);
  if (FLogViewer <> nil) and FLogViewer.Visible then
    FProject.Windows.Put(WINKEY_LOGVIEWER, FLogViewer.Left, FLogViewer.Top,
      FLogViewer.Width, FLogViewer.Height, SavedWindowStateOf(FLogViewer));
  if (FBrowserWindow <> nil) and FBrowserWindow.Visible then
    FProject.Windows.Put(WINKEY_BROWSER, FBrowserWindow.Left, FBrowserWindow.Top,
      FBrowserWindow.Width, FBrowserWindow.Height, SavedWindowStateOf(FBrowserWindow));
  if FOpenVST2Editors <> nil then
    for i := 0 to FOpenVST2Editors.Count - 1 do
    begin
      frm := FOpenVST2Editors[i];
      if frm.WindowKey <> '' then
        FProject.Windows.Put(frm.WindowKey, frm.Left, frm.Top, frm.Width, frm.Height,
          SavedWindowStateOf(frm));
    end;
end;

procedure TfrmMain.RestoreWindowLayout;
var
  i, stripId, idx, sep: Integer;
  e: TWindowLayoutEntry;
  keyTail: string;
begin
  if FProject = nil then Exit;

  e := FProject.Windows.Find(WINKEY_TIMELINEVIEW);
  if (e <> nil) and (FTlView <> nil) and (e.Left > 0) then
  begin
    FTlView.SetZoom(e.Left / 1000.0);
    FTlView.ScrollToSeconds(e.Top / 1000.0);
    RefreshTimelineTab;
    pbTimeline.Invalidate;
  end;

  if FProject.Windows.Find(WINKEY_LOGVIEWER) <> nil then
    ShowLogClick(nil);

  if FProject.Windows.Find(WINKEY_BROWSER) <> nil then
    OpenBrowserWindowClick(nil);

  { Every remembered VST2 editor: key is "VST2Editor:<stripId>:<insertIndex>"
    (see OpenVST2EditorForInsert). A malformed key or an insert that no
    longer exists in this project is dropped rather than left to fail again
    on every future load. }
  for i := FProject.Windows.Entries.Count - 1 downto 0 do
  begin
    e := FProject.Windows.Entries[i];
    if not e.Key.StartsWith(WINKEY_VST2_PREFIX, True) then Continue;
    keyTail := Copy(e.Key, Length(WINKEY_VST2_PREFIX) + 1, MaxInt);
    sep := Pos(':', keyTail);
    if (sep = 0) or
       not TryStrToInt(Copy(keyTail, 1, sep - 1), stripId) or
       not TryStrToInt(Copy(keyTail, sep + 1, MaxInt), idx) then
    begin
      FProject.Windows.Remove(e.Key);
      Continue;
    end;
    if not OpenVST2EditorForInsert(stripId, idx) then
      FProject.Windows.Remove(e.Key);
  end;
end;

procedure TfrmMain.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  StopLiveRecording;
  CaptureOpenWindowLayout;
  FormResize(nil);
  if (App <> nil) and (App.Config <> nil) then
    if not App.Config.Save then Logger.Warn('ui', 'Could not save window state on close');
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
var
  i: Integer;
begin
  FormResize(nil);
  if (App <> nil) and (App.Config <> nil) then
    if not App.Config.Save then Logger.Warn('ui', 'Could not save window state');
  FWindowStateReady := False;
  {$IFNDEF FPC}
  TUDAWLicense.OnStateChanged := nil;   // the callback captures this form
  {$ENDIF}
  tmrUI.Enabled := False;
  StopLiveRecording;
  FreeAndNil(FOpenVST2Editors);   // does not own the forms - they free via caFree or MainForm's own ownership
  {$IFNDEF FPC}
  FreeAndNil(FKeyHooks);   // unregisters every hotkey with the OS
  {$ENDIF}
  FreeAndNil(FTrkPatternBuffer);
  FreeAndNil(FTrkSequenceBuffer);
  FreeAndNil(FTrkInstrWaveBuffer);
  {$IFNDEF FPC}
  DragAcceptFiles(Handle, False);
  {$ENDIF}
  if (App <> nil) and (App.Audio <> nil) and (FGraphPlaying or FWavPlaying or FTrkPlaying or FTlPlaying) then
    App.Audio.ClearSource;
  FGraphPlaying := False;
  FWavPlaying := False;
  FWavSource := nil;
  FMidiEngine := nil;
  FMidiEngineRef := nil;
  FreeAndNil(FMidiInDevice);    // closes the device (Destroy calls Close)
  FreeAndNil(FMidiOutDevice);
  FreeAndNil(FMidiCapture);
  FreeAndNil(FMidiMonitorSynth);
  FTrkPlaying := False;
  FreeAndNil(FTrkPlayer);
  FTlPlaying := False;
  FreeAndNil(FTlPlayer);
  FreeAndNil(FTlCacheHolder);
  FTlWaveformWarned.Free;
  if App <> nil then
  begin
    App.Jobs.CancelAll;
    App.Jobs.WaitAll; // workers must finish before caller-owned jobs are freed
  end;
  if FRecoverySessionActive then
    FRecovery.EndSessionClean;
  FRecovery.Free;
  FComp.Free;
  FCompLane.Free;
  FRec.Free;
  FRecovery2.Free;
  FMixSession.Free;
  FMasterSession.Free;
  FCmds.Free;
  FProject.Free;
  FGraph.Free;
  FTlView.Free;
  FTlBuffer.Free;
  FTlMeterBuffer.Free;
  FTlSpectrum.Free;
  FMixBuffer.Free;
  FMixAutoBuffer.Free;
  FRecBuffer.Free;
  FDspBuffer.Free;
  for i := 0 to FTrackedJobs.Count - 1 do
    TJob(FTrackedJobs[i]).Free;
  FTrackedJobs.Free;
  FScopeSpectrum.Free;
  FScopeSpectrogram.Free;
  FScopeGonio.Free;
  FScopeCapture.Free;
  FAiMcpServers.Free;
  FMcpServer.Free;
  FMcpBridge.Free;
  FSunoRefCapture.Free; // discards any in-progress reference recording, same as a cancelled take
  FSunoRefs.Free;
end;

procedure TfrmMain.FormResize(Sender: TObject);
begin
  if not FWindowStateReady or (App = nil) or (App.Config = nil) then Exit;
  { minimized geometry is meaningless to persist - leave the last known good
    normal/maximized state alone until the window is normal or maximized again }
  case WindowState of
    wsNormal:
      begin
        App.Config.SetBool(CFG_SEC_UI, CFG_UI_MAXIMIZED, False);
        App.Config.SetInt(CFG_SEC_UI, CFG_UI_WIDTH, Width);
        App.Config.SetInt(CFG_SEC_UI, CFG_UI_HEIGHT, Height);
      end;
    wsMaximized:
      App.Config.SetBool(CFG_SEC_UI, CFG_UI_MAXIMIZED, True);
  end;
end;

{ Single source of truth for every app-focused key hook (fixed rows below) plus
  the live state of every global/system-wide hook owned by FKeyHooks, so the
  Settings > Key Hooks list can never drift from what FormKeyDown/WMHotKey
  actually does. Fixed rows have Data = nil (not reassignable); global-hook
  rows have Data = Pointer(hookIndex + 1) so btnKeyHookAssignClick and
  FormKeyDown's capture-mode branch can find the matching FKeyHooks entry. }
const
  KeyHookTable: array[0..21] of record
    Action, Keys, Context: string;
  end = (
    (Action: 'Project: New'; Keys: 'Ctrl+N'; Context: 'Global (not while typing in a text field)'),
    (Action: 'Undo'; Keys: 'Ctrl+Z'; Context: 'Global (not while typing in a text field)'),
    (Action: 'Redo'; Keys: 'Ctrl+Y or Ctrl+Shift+Z'; Context: 'Global (not while typing in a text field)'),
    (Action: 'Delete active channel (Timeline track + Mixer strip)'; Keys: 'Delete'; Context: 'Timeline tab'),
    (Action: 'Delete selected clip'; Keys: 'Backspace'; Context: 'Timeline tab, with a clip selected'),
    (Action: 'New Timeline (add channel)'; Keys: 'Insert'; Context: 'Timeline tab'),
    (Action: 'Go to start of Timeline'; Keys: 'Home'; Context: 'Timeline tab'),
    (Action: 'Go to end of Timeline'; Keys: 'End'; Context: 'Timeline tab'),
    (Action: 'Project: Open'; Keys: 'Ctrl+O'; Context: 'Global (not while typing in a text field)'),
    (Action: 'Project: Save'; Keys: 'Ctrl+S'; Context: 'Global (not while typing in a text field)'),
    (Action: 'Project: Save As'; Keys: 'Ctrl+Shift+S'; Context: 'Global (not while typing in a text field)'),
    (Action: 'Pan the Timeline horizontally'; Keys: 'Middle mouse button + drag'; Context: 'Timeline tab'),
    (Action: 'Position the playhead (start point)'; Keys: 'Left click'; Context: 'Timeline ruler (top time area) only'),
    (Action: 'Highlight / select a time range'; Keys: 'Left mouse button + drag'; Context: 'Timeline ruler or empty lane space'),
    (Action: 'Move the selected range'; Keys: 'Right mouse button + drag'; Context: 'Timeline lane, with a range selected'),
    (Action: 'Open Timeline context menu'; Keys: 'Right click (no drag)'; Context: 'Timeline lane / ruler'),
    (Action: 'Resize the channel header column'; Keys: 'Left mouse button + drag'; Context: 'Timeline, header-side edge of the column divider'),
    (Action: 'Move clip(s)'; Keys: 'Left mouse button + drag'; Context: 'Timeline, on a clip'),
    (Action: 'Duplicate clip(s) while dragging'; Keys: 'Alt + left drag'; Context: 'Timeline, on a clip'),
    (Action: 'Add to / toggle clip selection'; Keys: 'Ctrl or Shift + click'; Context: 'Timeline, on a clip'),
    (Action: 'Rubber-band select clips'; Keys: 'Ctrl or Shift + left drag'; Context: 'Timeline, empty lane space'),
    (Action: 'Zoom the Timeline'; Keys: 'Mouse wheel'; Context: 'Timeline tab')
  );

procedure TfrmMain.LoadKeyHooksTab;
var
  i: Integer;
  it: TListItem;
  {$IFNDEF FPC}
  h: TKeyHookDef;
  status: string;
  {$ENDIF}
begin
  lvKeyHooks.Items.BeginUpdate;
  try
    lvKeyHooks.Items.Clear;
    for i := Low(KeyHookTable) to High(KeyHookTable) do
    begin
      it := lvKeyHooks.Items.Add;
      it.Caption := KeyHookTable[i].Action;
      it.SubItems.Add(KeyHookTable[i].Keys);
      it.SubItems.Add(KeyHookTable[i].Context);
      it.SubItems.Add('built-in (not reassignable)');
      it.Data := nil;
    end;
    {$IFNDEF FPC}
    if FKeyHooks <> nil then
      for i := 0 to FKeyHooks.Count - 1 do
      begin
        h := FKeyHooks.GetHook(i);
        it := lvKeyHooks.Items.Add;
        it.Caption := KeyHookActionName(h.Action);
        it.SubItems.Add(FKeyHooks.KeysToString(h.Modifiers, h.VirtualKey));
        it.SubItems.Add('Global (works even when UDAW is not the focused window)');
        if not h.Enabled then status := 'disabled'
        else if h.Registered then status := 'OK'
        else status := 'FAILED: ' + h.LastError;
        it.SubItems.Add(status);
        it.Data := Pointer(NativeInt(i + 1));
      end;
    {$ENDIF}
  finally
    lvKeyHooks.Items.EndUpdate;
  end;
end;

{$IFNDEF FPC}
{ Applies every configured global hook on startup. Failures are logged and
  left visible (per-row, with the OS error text) on the Key Hooks tab rather
  than silently dropped - see LoadKeyHooksTab. }
procedure TfrmMain.ApplyKeyHooksOnStartup;
var
  failCount: Integer;
begin
  if (App = nil) or (FKeyHooks = nil) then Exit;
  FKeyHooks.LoadFromConfig(App.Config);
  failCount := FKeyHooks.ApplyAll;
  if failCount > 0 then
    Logger.Warn('KeyHooks', Format(
      '%d global key hook(s) could not be applied at startup - see Settings > Key Hooks.',
      [failCount]))
  else
    Logger.Info('KeyHooks', 'All global key hooks applied.');
end;

{ Ctrl+Pause/Break by default: unconditional, instant, never raises - closes
  and saves whatever audio take is currently recording, regardless of which
  tab or state UDAW is in. }
procedure TfrmMain.DoEmergencyStop;
begin
  if FRecWriter <> nil then StopLiveRecording;
  stbMain.SimpleText := 'Emergency stop: recordings closed and saved.';
end;

{ Global toggle for timeline transport - lets the user start/stop playback
  from anywhere on the system without switching to the UDAW window. }
procedure TfrmMain.DoToggleTimelinePlayback;
begin
  if FTlPlaying then
  begin
    StopTimelinePlayback;
    RefreshTimelineTab;
    stbMain.SimpleText := 'Timeline playback stopped.';
  end
  else
  begin
    StartTimelinePlayback(False, False, False);
    stbMain.SimpleText := 'Timeline playback started.';
  end;
end;

{ Global "panic" - immediately silences whatever is currently playing
  (timeline, tracker, graph/WAV preview) without touching recording or video
  capture, which khaEmergencyStop already covers. }
procedure TfrmMain.DoPanicStopAudio;
begin
  if FTlPlaying then StopTimelinePlayback;
  if FTrkPlaying then btnTrkStopClick(nil);
  if (App <> nil) and (App.Audio <> nil) and (FGraphPlaying or FWavPlaying) then
    App.Audio.ClearSource;
  FGraphPlaying := False;
  FWavPlaying := False;
  RefreshTimelineTab;
  stbMain.SimpleText := 'Panic: all audio playback stopped.';
end;

{ Global master-output mute toggle. }
procedure TfrmMain.DoToggleMasterMute;
var
  master: TMixStrip;
begin
  if FProject = nil then Exit;
  master := FProject.Mixer.MasterStrip;
  if master = nil then Exit;
  master.Muted := not master.Muted;
  RefreshMixerTab;
  if master.Muted then
    stbMain.SimpleText := 'Master output muted.'
  else
    stbMain.SimpleText := 'Master output unmuted.';
end;

procedure TfrmMain.WMHotKey(var Msg: TMessage);
var
  action: TKeyHookAction;
begin
  if (FKeyHooks <> nil) and FKeyHooks.ActionForHotkeyId(Msg.WParam, action) then
  begin
    case action of
      khaEmergencyStop: DoEmergencyStop;
      khaStopRecording: if FRecWriter <> nil then StopLiveRecording;
      khaTogglePlayback: DoToggleTimelinePlayback;
      khaPanicStopAudio: DoPanicStopAudio;
      khaToggleMasterMute: DoToggleMasterMute;
    end;
    Msg.Result := 0;
  end;
end;

procedure TfrmMain.btnKeyHookAssignClick(Sender: TObject);
begin
  if lvKeyHooks.Selected = nil then
  begin
    lblKeyHooksHint.Caption := 'Select a row first, then click Assign New Key.';
    Exit;
  end;
  if NativeInt(lvKeyHooks.Selected.Data) - 1 < 0 then
  begin
    lblKeyHooksHint.Caption := 'That row is a built-in shortcut and cannot be reassigned.';
    Exit;
  end;
  FKeyHookCaptureRow := lvKeyHooks.Selected.Index;
  lblKeyHooksHint.Caption := 'Press the new key combination now (Esc to cancel)...';
end;

procedure TfrmMain.btnKeyHookSaveClick(Sender: TObject);
begin
  if (FKeyHooks = nil) or (App = nil) then Exit;
  FKeyHooks.SaveToConfig(App.Config);
  lblKeyHooksHint.Caption := 'Key hooks saved.';
  LoadKeyHooksTab;
end;

procedure TfrmMain.btnKeyHookRestoreClick(Sender: TObject);
begin
  if (FKeyHooks = nil) or (App = nil) then Exit;
  FKeyHooks.RestoreDefaults(App.Config);
  lblKeyHooksHint.Caption := 'All key hooks restored to their defaults.';
  LoadKeyHooksTab;
end;

{ Lets the user "get rid of" a hook that keeps failing (rather than only
  reassign it) - toggles Enabled and re-applies, without disturbing the
  other rows. Re-click to bring it back. }
procedure TfrmMain.btnKeyHookToggleClick(Sender: TObject);
var
  hookIdx: Integer;
  h: TKeyHookDef;
begin
  if (FKeyHooks = nil) or (lvKeyHooks.Selected = nil) then Exit;
  hookIdx := NativeInt(lvKeyHooks.Selected.Data) - 1;
  if hookIdx < 0 then
  begin
    lblKeyHooksHint.Caption := 'That row is a built-in shortcut and cannot be disabled.';
    Exit;
  end;
  h := FKeyHooks.GetHook(hookIdx);
  FKeyHooks.SetEnabled(hookIdx, not h.Enabled);
  if not h.Enabled then
    lblKeyHooksHint.Caption := KeyHookActionName(h.Action) + ' enabled - click Save to keep it.'
  else
    lblKeyHooksHint.Caption := KeyHookActionName(h.Action) + ' disabled - click Save to keep it.';
  LoadKeyHooksTab;
end;
{$ENDIF}

{ Global shortcuts (KeyPreview = True in the .dfm routes every keystroke here
  first). Delete only acts on the Timeline tab's own selection - it must not
  fire from an editbox/memo elsewhere in the form, so it's gated on both the
  active tab and the focused control not being a text-editing one. Undo/Redo
  are safe everywhere: FCmds is the one shared TCommandManager every tab's
  own Undo/Redo buttons already call (see btnTlUndoClick etc.), so Ctrl+Z/
  Ctrl+Y here is just another caller of the same thing.
  Every branch below corresponds to one row of KeyHookTable above - keep both
  in sync when adding, removing or rebinding a shortcut. }
procedure TfrmMain.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  inTextEditor: Boolean;
  {$IFNDEF FPC}
  mods: Word;
  err: string;
  hookIdx: Integer;
  {$ENDIF}
begin
  {$IFNDEF FPC}
  if FKeyHookCaptureRow >= 0 then
  begin
    if Key in [VK_CONTROL, VK_MENU, VK_SHIFT, VK_LWIN, VK_RWIN] then
      Exit;   // wait for a real key, not the modifier being held on the way there
    hookIdx := NativeInt(lvKeyHooks.Items[FKeyHookCaptureRow].Data) - 1;
    if Key = VK_ESCAPE then
      lblKeyHooksHint.Caption := 'Assignment cancelled - key hook unchanged.'
    else if hookIdx < 0 then
      lblKeyHooksHint.Caption := 'That row is not reassignable.'
    else
    begin
      mods := 0;
      if ssCtrl in Shift then mods := mods or MOD_CONTROL;
      if ssAlt in Shift then mods := mods or MOD_ALT;
      if ssShift in Shift then mods := mods or MOD_SHIFT;
      if FKeyHooks.TrySetKeys(hookIdx, mods, Key, err) then
        lblKeyHooksHint.Caption := 'Key hook updated - click Save to keep it.'
      else
        lblKeyHooksHint.Caption := 'Could not apply that combination: ' + err;
    end;
    FKeyHookCaptureRow := -1;
    LoadKeyHooksTab;
    Key := 0;
    Exit;
  end;
  {$ENDIF}
  inTextEditor := (ActiveControl is TCustomEdit) or (ActiveControl is TCustomMemo);
  if inTextEditor then Exit;   // leave native single-field undo/typing alone

  if (Key = Ord('Z')) and (Shift = [ssCtrl]) then
  begin
    FCmds.Undo;
    RefreshTimelineTab;
    Key := 0;
    Exit;
  end;
  if ((Key = Ord('Y')) and (Shift = [ssCtrl])) or
     ((Key = Ord('Z')) and (Shift = [ssCtrl, ssShift])) then
  begin
    FCmds.Redo;
    RefreshTimelineTab;
    Key := 0;
    Exit;
  end;

  if (Shift = []) and (pgc.ActivePage = tabTimeline) then
    case Key of
      VK_DELETE:
        begin
          DeleteActiveChannel;
          Key := 0;
        end;
      VK_BACK:
        begin
          if FTlSelClipId >= 0 then
            btnTlDeleteClipClick(Self);
          Key := 0;
        end;
      VK_INSERT:
        begin
          btnTlAddTrackClick(Self);
          Key := 0;
        end;
      VK_HOME:
        begin
          btnTlGoStartClick(Self);
          Key := 0;
        end;
      VK_END:
        begin
          btnTlGoEndClick(Self);
          Key := 0;
        end;
    end;
end;

{ DEL: removes the active channel (last-selected/clicked Timeline track) and
  the Mixer strip fed by it, as two undoable commands. Refused during
  playback for the same reason btnMixRemoveClick is. }
procedure TfrmMain.DeleteActiveChannel;
var
  trackId, j: Integer;
  stripId: Integer;
begin
  if FProject = nil then Exit;
  trackId := FTlSelectedTrackId;
  if trackId < 0 then trackId := FTlCtxTrackId;
  if (trackId < 0) or (FProject.Timeline.TrackById(trackId) = nil) then Exit;
  if FGraphPlaying or FWavPlaying or FTrkPlaying or FTlPlaying then Exit;
  stripId := 0;
  for j := 0 to FProject.Mixer.StripCount - 1 do
    if FProject.Mixer.GetStrip(j).InputSourceId = trackId then
    begin
      stripId := FProject.Mixer.GetStrip(j).Id;
      Break;
    end;
  try
    if stripId <> 0 then
      FCmds.Perform(TRemoveMixStripCommand.Create(FProject, stripId));
  except
    on E: EUDAWError do ;  // strip may be non-removable; still remove the track
  end;
  FTlCtxTrackId := trackId;
  btnTlRemoveTrackClick(Self);
  RefreshMixerTab;
end;

procedure TfrmMain.RefreshSystemTab;
begin
  if App <> nil then
    memSystem.Lines.Text := App.DescribeStartup
  else
    memSystem.Lines.Text := '(application core not initialised)';
end;

procedure TfrmMain.PumpLog;
var
  snap: TArray<TLogEntry>;
  i: Integer;
  it: TListItem;
begin
  if (App = nil) or (App.MemoryLog = nil) then
    Exit;
  snap := App.MemoryLog.Snapshot;
  if Length(snap) < FLogShown then
    FLogShown := 0;   { sink was cleared }
  lvLog.Items.BeginUpdate;
  try
    for i := FLogShown to High(snap) do
    begin
      it := lvLog.Items.Add;
      it.Caption := FormatDateTime('hh:nn:ss.zzz', snap[i].Time);
      it.SubItems.Add(LevelName(snap[i].Level));
      it.SubItems.Add(snap[i].Subsystem);
      it.SubItems.Add(snap[i].Text);
      it.Data := Pointer(NativeInt(Ord(snap[i].Level)));
    end;
    FLogShown := Length(snap);
    while lvLog.Items.Count > 5000 do
      lvLog.Items.Delete(0);
  finally
    lvLog.Items.EndUpdate;
  end;
  if lvLog.Items.Count > 0 then
    lvLog.Items[lvLog.Items.Count - 1].MakeVisible(False);
end;

procedure TfrmMain.RefreshJobs;
var
  i: Integer;
  job, runningJob: TJob;
  it: TListItem;
begin
  lvJobs.Items.BeginUpdate;
  try
    lvJobs.Items.Clear;
    runningJob := nil;
    for i := 0 to FTrackedJobs.Count - 1 do
    begin
      job := TJob(FTrackedJobs[i]);
      it := lvJobs.Items.Add;
      it.Caption := IntToStr(job.Id);
      it.SubItems.Add(job.Title);
      it.SubItems.Add(JobStatusName(job.Status));
      it.SubItems.Add(Format('%.0f%%  %s', [job.Progress * 100, job.Note]));
      if (runningJob = nil) and (job.Status = jsRunning) then
        runningJob := job;
    end;
  finally
    lvJobs.Items.EndUpdate;
  end;

  { Tracked jobs are submitted with ownsJob=False, so we own them. They stay in
    the list (and visible) until the window closes; FormDestroy frees them. }

  { A synchronous ShowStatusProgress/HideStatusProgress-bracketed operation
    (import, timeline "first render", etc.) already owns stbMain/prgStatus
    for as long as it runs - never fight it for the status bar here. }
  if FSyncProgressActive then Exit;

  if App <> nil then
  begin
    if runningJob <> nil then
    begin
      prgStatus.Min := 0;
      prgStatus.Max := 100;
      prgStatus.Position := Round(runningJob.Progress * 100);
      prgStatus.Visible := True;
      stbMain.SimpleText := Format('%s: %.0f%%  %s',
        [runningJob.Title, runningJob.Progress * 100, runningJob.Note]);
    end
    else
    begin
      prgStatus.Visible := False;
      stbMain.SimpleText := Format(
        'jobs: %d worker threads, %d active, %d pending   |   log dropped: %d',
        [App.Jobs.WorkerCount, App.Jobs.ActiveCount, App.Jobs.PendingCount,
         Logger.DroppedCount]);
    end;
  end;
end;

procedure TfrmMain.tmrUITimer(Sender: TObject);
begin
  {$IFNDEF FPC}
  { licence server unreachable: keep the Registration page's countdown live,
    and shut down once it hits zero so the next start re-verifies online. The
    project is autosaved first so nothing is lost. }
  if TUDAWLicense.OfflineSecondsRemaining >= 0 then
  begin
    UpdateRegistrationUI;
    if TUDAWLicense.OfflineExpired then
    begin
      tmrUI.Enabled := False;
      Logger.Warn('license', 'Offline limit reached - shutting down to force re-verification.');
      try
        if FRecoverySessionActive then FRecovery.AutosaveNow(FProject);
      except
      end;
      Application.Terminate;
      Exit;
    end;
  end;
  {$ENDIF}
  if (FMidiInDevice <> nil) and FMidiInDevice.IsOpen then
    FMidiInDevice.Poll(HandleLiveMidiInput, Self);
  if FRecWriter <> nil then
  begin
    RefreshRecordingTab;
    if (FRecWriter.ErrorCount > 0) or (FRecWriter.RingOverruns > 0) or
       (App.Audio.State <> aesRunning) or
       ((FRecWriter.FramesConsumed = 0) and (GetTickCount64 - FRecStarted > 5000)) then
      StopLiveRecording;
  end;
  FinishSunoJob;
  FinishLumaJob;
  TrackTimelineExportStage;
  FinishTimelineExport;
  FinishTimelinePrepare;
  DrainSunoRefRecording;
  PumpLog;
  RefreshJobs;
  RefreshAudio;
  if chkDspLive.Checked and (ActiveWorkspacePage = tabDSP) then
    RunDspAnalysis;
  if chkGraphLive.Checked and (ActiveWorkspacePage = tabGraph) then
    RunGraphAnalysis;
  if chkScopeLive.Checked and (ActiveWorkspacePage = tabScope) then
    RunScopeAnalysis;
  ProjectTick;
  { guarded the same way as Timeline/Mixer/Tracker below: WM_TIMER keeps
    reaching tmrUITimer during pmProject's modal popup loop, and repainting
    the tab underneath it every tick is what left the popup blank/flickering
    until a mouse move forced Windows to redraw it - see FMenuLoopActive's
    declaration comment. }
  if (pgc.ActivePage = tabProject) and (not FMenuLoopActive) then
    RefreshProjectTab;
  if (pgc.ActivePage = tabTimeline) and (not FMenuLoopActive) then
    { Skip the tick entirely - not just the menu Enabled/Caption/Checked sync -
      while the Timeline menu bar item or pmTimeline is actually on screen.
      RefreshTimelineTab always ends with pbTimeline.Invalidate regardless of
      AFull, and WM_TIMER keeps reaching tmrUITimer during TrackPopupMenu's
      modal loop (see FMenuLoopActive's declaration comment), so leaving this
      unconditional had pbTimeline repainting itself under the live popup on
      every tick. Win32's themed/owner-draw popup does not repaint over that
      churn, which is what left pmTimeline blank/flickering until a mouse
      move over its items forced Windows to redraw them. }
    begin
      RefreshTimelineTab(not FTlPlaying);
      if FTlPlaying and (App <> nil) and (App.Audio <> nil) then
      begin
        UpdateTimelineMeterChannel(FTlMeterL, App.Audio.OutputPeak(0));
        if App.Audio.OutputChannels > 1 then
          UpdateTimelineMeterChannel(FTlMeterR, App.Audio.OutputPeak(1))
        else
          UpdateTimelineMeterChannel(FTlMeterR, App.Audio.OutputPeak(0));
        pbTlMeters.Invalidate;
        if App.Audio.Granted.SampleRate > 0 then
        begin
          if FTlSpecRate <> App.Audio.Granted.SampleRate then
          begin
            FTlSpecRate := App.Audio.Granted.SampleRate;
            FTlSpectrum.Configure(FTlSpecRate, 2048);
            SetLength(FTlSpecDb, FTlSpectrum.SpectrumBins);
          end;
          App.Audio.CopyRecentOutput(@FTlSpecTap[0], Length(FTlSpecTap));
          FTlSpectrum.PushBlock(@FTlSpecTap[0], Length(FTlSpecTap));
          FTlSpectrum.GetSpectrumDb(FTlSpecDb);
          FTlSpecActive := True;
        end;
      end
      else
        FTlSpecActive := False;
    end;
  if pgc.ActivePage = tabRecording then
    RefreshRecordingTab;
  if (pgc.ActivePage = tabMixer) and (not FMenuLoopActive) then
    { Cheap repaint only (live meters/hold-caps/clip-LEDs/automation playhead) -
      never the full RefreshMixerTab (which rebuilds combos and would also
      mutate pmMixer's items) from a per-tick path; see pmMixerPopup's header
      comment for exactly the flicker/stale-menu bug that guards against. }
    begin
      pbMixer.Invalidate;
      pbMixAuto.Invalidate;
    end;
  if FTlPlaying then
    AdvanceTimelinePlayback;
  if FTrkPlaying and (pgc.ActivePage = tabTracker) and not FMenuLoopActive then
    RefreshTrackerTab(False);
end;

{ ---- DSP foundation demo (Phase 3): render a signal through a DSP chain and
       analyse it with the internal FFT + meters. Every control is design-time;
       only pixels are painted at run time. ---- }

procedure TfrmMain.RunDspAnalysis;
const
  SR = 48000;
  NFFT = 4096;
var
  src: IAudioSource;
  res: TOfflineResult;
  bqA: TBiquad;
  chain: TBiquadChain;
  useChain: Boolean;
  ch, i, first: Integer;
  frame: array of Single;
  fft: TFFT;
  win: TWindowKind;
  rms: TRmsMeter;
  tp: TTruePeakMeter;
  loud: TLoudnessMeter;
  corr: TCorrelationMeter;
  fr: array[0..1] of Single;

  function MagAt(AFreq: Double): Double;
  begin
    if useChain then
      Result := chain.MagnitudeDb(AFreq)
    else
      Result := bqA.MagnitudeDb(AFreq);
  end;

begin
  if cboDspSignal.ItemIndex = 5 then
  begin
    { run the filter / FFT / meters against the real project: 1 s of the
      timeline mix starting at the playhead-independent project start }
    res := RenderProjectMixOffline(1.0, SR);
    if res.Frames = 0 then
    begin
      memDspReadout.Lines.Text := '(no project open, or the timeline has no audio to analyze)';
      Exit;
    end;
  end
  else
  begin
    case cboDspSignal.ItemIndex of
      0: src := TToneSource.Create(osSine, 440.0, 0.5);
      2: src := TSweepSource.Create(20, 20000, 1.0, 0.5, True);
      3: src := TToneSource.Create(osWhiteNoise, 0, 0.5);
      4: src := TToneSource.Create(osPinkNoise, 0, 0.5);
    else
      src := TToneSource.Create(osSine, 1000.0, 0.5);
    end;
    res := RenderSourceOffline(src, SR, 2, SR, 512);   // 1 s stereo
  end;

  chain := nil;
  useChain := False;
  bqA.Init(SR);
  case cboDspFilter.ItemIndex of
    1: bqA.SetParams(bqLowpass, 1000, 0.70710678);
    2: bqA.SetParams(bqHighpass, 200, 0.70710678);
    3: bqA.SetParams(bqPeaking, 2000, 2.0, 6.0);
    4: bqA.SetParams(bqNotch, 1000, 8.0);
    5: useChain := True;
  else
    bqA.SetParams(bqAllpass, 1000, 0.5);   // bypass ~ allpass (flat magnitude)
  end;

  if useChain then
  begin
    chain := TBiquadChain.Create(SR, 2);
    chain.SetButterworthLowpass(500);
  end;

  try
    if cboDspFilter.ItemIndex <> 0 then
      for ch := 0 to res.Channels - 1 do
      begin
        if useChain then
          chain.Reset
        else
          bqA.Reset;
        for i := 0 to res.Frames - 1 do
          if useChain then
            res.Planar[ch][i] := chain.ProcessSample(res.Planar[ch][i])
          else
            res.Planar[ch][i] := bqA.ProcessSample(res.Planar[ch][i]);
      end;

    { spectrum of the last NFFT samples of channel 0 }
    SetLength(FDspDb, NFFT div 2 + 1);
    FDspNyquist := SR / 2;
    if res.Frames >= NFFT then
    begin
      SetLength(frame, NFFT);
      first := res.Frames - NFFT;
      for i := 0 to NFFT - 1 do
        frame[i] := res.Planar[0][first + i];
      case cboDspWindow.ItemIndex of
        0: win := wkRect;
        2: win := wkHamming;
        3: win := wkBlackman;
        4: win := wkBlackmanHarris;
      else
        win := wkHann;
      end;
      fft := TFFT.Create(NFFT);
      try
        fft.AnalyzeDb(frame, win, FDspDb);
      finally
        fft.Free;
      end;
    end;

    { meters over the whole rendered second }
    rms.Init(SR, 400);
    tp.Init(SR, 4, 24);
    loud := TLoudnessMeter.Create(SR, 2);
    corr.Init(SR, 400);
    try
      for i := 0 to res.Frames - 1 do
      begin
        rms.Push(res.Planar[0][i]);
        tp.Push(res.Planar[0][i]);
        fr[0] := res.Planar[0][i];
        fr[1] := res.Planar[1][i];
        loud.PushFrame(fr);
        corr.Push(res.Planar[0][i], res.Planar[1][i]);
      end;

      FDspReadout := Format(
        'signal : %s'#13#10 +
        'filter : %s'#13#10 +
        'window : %s   FFT %d'#13#10 +
        '--------------------------------------'#13#10 +
        'RMS (400 ms)      : %7.2f dBFS'#13#10 +
        'True peak (4x)     : %7.2f dBTP'#13#10 +
        'Integrated loudness: %7.2f LUFS'#13#10 +
        'Momentary loudness : %7.2f LUFS'#13#10 +
        'Stereo correlation : %7.3f',
        [cboDspSignal.Text, cboDspFilter.Text, cboDspWindow.Text, NFFT,
         rms.ValueDb, tp.ValueDb, loud.Integrated, loud.Momentary, corr.Value]);
      if cboDspFilter.ItemIndex in [1..5] then
        FDspReadout := FDspReadout + #13#10 +
          '--------------------------------------'#13#10 +
          Format('filter |H| : 100 Hz %.1f dB, 1 kHz %.1f dB, 10 kHz %.1f dB',
            [MagAt(100), MagAt(1000), MagAt(10000)]);
    finally
      loud.Free;
    end;
  finally
    chain.Free;
  end;

  { same full-text-replace-every-tick flicker as RefreshAudio's memAudio -
    see that method's comment. }
  memDspReadout.Lines.BeginUpdate;
  try
    memDspReadout.Lines.Text := FDspReadout;
  finally
    memDspReadout.Lines.EndUpdate;
  end;
  pbSpectrum.Invalidate;
end;

{ ---- Scope (Phase 18): spectrum / spectrogram / goniometer / oscilloscope /
       ballistics meters over a synthetic demo signal, mirroring the DSP tab's
       offline-render-then-analyse pattern. ---- }

procedure TfrmMain.RunScopeAnalysis;
const
  SR = 48000;
var
  src: IAudioSource;
  res: TOfflineResult;
  bins: Integer;
begin
  if cboScopeSignal.ItemIndex = 5 then
  begin
    res := RenderProjectMixOffline(1.0, SR);   // 1 s stereo, matching the synthetic path below
    if res.Frames = 0 then
    begin
      memScopeReadout.Lines.Text := '(no project open, or the timeline has no audio to analyze)';
      Exit;
    end;
  end
  else
  begin
    case cboScopeSignal.ItemIndex of
      0: src := TToneSource.Create(osSine, 440.0, 0.5);
      2: src := TSweepSource.Create(20, 20000, 1.0, 0.5, True);
      3: src := TToneSource.Create(osWhiteNoise, 0, 0.5);
      4: src := TToneSource.Create(osPinkNoise, 0, 0.5);
    else
      src := TToneSource.Create(osSine, 1000.0, 0.5);
    end;
    res := RenderSourceOffline(src, SR, 2, SR, 512);   // 1 s stereo
  end;

  FScopeSpectrum.Configure(SR, 2048);
  FScopeSpectrogram.Configure(SR, 2048, 256);
  FScopeGonio.Configure(SR, 2048);
  FScopeCapture.Configure(SR, 2048);
  FScopeCapture.SetTriggerMode(True);
  FScopeBallL.Configure(SR, mbDigitalPeak);
  FScopeBallR.Configure(SR, mbDigitalPeak);

  FScopeSpectrum.PushBlock(@res.Planar[0][0], res.Frames);
  FScopeSpectrogram.PushBlock(@res.Planar[0][0], res.Frames);
  FScopeGonio.PushBlock(@res.Planar[0][0], @res.Planar[1][0], res.Frames);
  FScopeCapture.PushBlock(@res.Planar[0][0], res.Frames);
  FScopeBallL.PushBlock(@res.Planar[0][0], res.Frames);
  FScopeBallR.PushBlock(@res.Planar[1][0], res.Frames);

  bins := FScopeSpectrum.SpectrumBins;
  SetLength(FScopeSpecDb, bins);
  FScopeSpectrum.GetSpectrumDb(FScopeSpecDb);
  FScopeNyquist := SR / 2;

  SetLength(FScopeSnapshot, 2048);
  FScopeSnapshotCount := FScopeCapture.GetSnapshot(FScopeSnapshot);

  FScopeReadout := Format(
    'signal : %s'#13#10 +
    'view   : %s'#13#10 +
    '--------------------------------------'#13#10 +
    'Correlation    : %7.3f'#13#10 +
    'Width estimate : %7.3f'#13#10 +
    'L peak         : %7.2f dBFS'#13#10 +
    'R peak         : %7.2f dBFS'#13#10 +
    'Spectrogram    : %d rows x %d bins'#13#10 +
    'Oscilloscope   : %s (%d samples captured)',
    [cboScopeSignal.Text, cboScopeMode.Text, FScopeGonio.Correlation,
     FScopeGonio.WidthEstimate, FScopeBallL.ReadingDb, FScopeBallR.ReadingDb,
     FScopeSpectrogram.RowCount, FScopeSpectrogram.BinCount,
     BoolToStr(FScopeCapture.HasSnapshot, True), FScopeSnapshotCount]);

  memScopeReadout.Lines.Text := FScopeReadout;
  pbScope.Invalidate;
end;

procedure TfrmMain.btnScopeAnalyzeClick(Sender: TObject);
begin
  RunScopeAnalysis;
end;

procedure TfrmMain.chkScopeLiveClick(Sender: TObject);
begin
  if chkScopeLive.Checked then
    RunScopeAnalysis;
end;

procedure TfrmMain.pbScopePaint(Sender: TObject);
var
  c: TCanvas;
  w, h, i, n, x, y, row, bin, rows, bins: Integer;
  topDb, botDb, hz, fmin, fmax, v: Double;
  px, py: Single;
  shade: Byte;
  db: array of Double;

  function XForHz(AHz: Double): Integer;
  begin
    if AHz < fmin then AHz := fmin;
    Result := Round((Ln(AHz) - Ln(fmin)) / (Ln(fmax) - Ln(fmin)) * (w - 1));
  end;

  function YForDb(ADb: Double): Integer;
  begin
    if ADb > topDb then ADb := topDb;
    if ADb < botDb then ADb := botDb;
    Result := Round((topDb - ADb) / (topDb - botDb) * (h - 1));
  end;

begin
  c := pbScope.Canvas;
  w := pbScope.Width;
  h := pbScope.Height;
  c.Brush.Color := CurrentTheme.Background;
  c.FillRect(Rect(0, 0, w, h));
  c.Pen.Color := CurrentTheme.Waveform;

  case cboScopeMode.ItemIndex of
    0:
    begin   { Spectrum }
      topDb := 6; botDb := -114;
      fmin := 20;
      if FScopeNyquist > fmin then fmax := FScopeNyquist else fmax := 24000;
      n := Length(FScopeSpecDb);
      if n >= 2 then
        for i := 0 to n - 1 do
        begin
          hz := i / (n - 1) * FScopeNyquist;
          if hz < fmin then hz := fmin;
          x := XForHz(hz);
          y := YForDb(FScopeSpecDb[i]);
          if i = 0 then c.MoveTo(x, y) else c.LineTo(x, y);
        end;
    end;
    1:
    begin   { Spectrogram }
      rows := FScopeSpectrogram.RowCount;
      bins := FScopeSpectrogram.BinCount;
      if (rows > 0) and (bins > 0) and (w > 0) and (h > 0) then
      begin
        SetLength(db, bins);
        for y := 0 to h - 1 do
        begin
          row := (y * rows) div h;
          if row > rows - 1 then row := rows - 1;
          FScopeSpectrogram.GetRow(row, db);
          for x := 0 to w - 1 do
          begin
            bin := (x * bins) div w;
            if bin > bins - 1 then bin := bins - 1;
            v := (db[bin] + 114) / 120;   // ~[-114..6] dB -> 0..1
            if v < 0 then v := 0;
            if v > 1 then v := 1;
            shade := Round(v * 255);
            c.Pixels[x, h - 1 - y] := TColor(shade or (shade shl 8) or (Min(255, shade + 40) shl 16));
          end;
        end;
      end;
    end;
    2:
    begin   { Goniometer }
      c.Pen.Color := CurrentTheme.Grid;
      c.MoveTo(w div 2, 0); c.LineTo(w div 2, h);
      c.MoveTo(0, h div 2); c.LineTo(w, h div 2);
      n := FScopeGonio.PointCount;
      for i := 0 to n - 1 do
      begin
        FScopeGonio.GetPoint(i, px, py);
        x := Round(w / 2 + px * (w / 2 - 2));
        y := Round(h / 2 - py * (h / 2 - 2));
        if (x >= 0) and (x < w) and (y >= 0) and (y < h) then
          c.Pixels[x, y] := CurrentTheme.Waveform;
      end;
    end;
    3:
    begin   { Oscilloscope }
      n := FScopeSnapshotCount;
      if n >= 2 then
        for i := 0 to n - 1 do
        begin
          x := Round(i / (n - 1) * (w - 1));
          y := Round(h / 2 - FScopeSnapshot[i] * (h / 2 - 2));
          if i = 0 then c.MoveTo(x, y) else c.LineTo(x, y);
        end;
    end;
  else
    begin   { Meters }
      c.Font.Color := CurrentTheme.SecondaryText;
      c.TextOut(8, 8, Format('L  %.2f dBFS  (scale %.2f)', [FScopeBallL.ReadingDb, FScopeBallL.ReadingScale01]));
      c.TextOut(8, 26, Format('R  %.2f dBFS  (scale %.2f)', [FScopeBallR.ReadingDb, FScopeBallR.ReadingScale01]));
      c.Brush.Color := CurrentTheme.Meter;
      c.FillRect(Rect(8, 50, 8 + Round(FScopeBallL.ReadingScale01 * (w - 16)), 74));
      c.FillRect(Rect(8, 84, 8 + Round(FScopeBallR.ReadingScale01 * (w - 16)), 108));
    end;
  end;
end;

{ ---- Advanced DSP (Phase 19): multiband compressor / mastering chain / time
       stretch / pitch shift over a synthetic demo signal. Offline tools, same
       render-then-process pattern as the DSP and Scope tabs. ---- }

procedure TfrmMain.RunAdvDspProcess;
const
  SR = 44100;
var
  src: IAudioSource;
  res: TOfflineResult;
  mb: TMultibandCompressor;
  mc: TMasteringChain;
  ts: TPhaseVocoderStretch;
  ps: TPitchShifter;
  outBuf: array[0..1] of TArray<Single>;
  stretched: TArray<Single>;
  ratio: Double;
  peakBefore, peakAfter, rmsBefore, rmsAfter: Double;
  i: Integer;
  readout: string;
begin
  if cboAdvDspSignal.ItemIndex = 5 then
  begin
    res := RenderProjectMixOffline(1.0, SR);
    if res.Frames = 0 then
    begin
      memAdvDspReadout.Lines.Text := '(no project open, or the timeline has no audio to process)';
      Exit;
    end;
  end
  else
  begin
    case cboAdvDspSignal.ItemIndex of
      0: src := TToneSource.Create(osSine, 440.0, 0.5);
      2: src := TSweepSource.Create(20, 20000, 1.0, 0.5, True);
      3: src := TToneSource.Create(osWhiteNoise, 0, 0.5);
      4: src := TToneSource.Create(osPinkNoise, 0, 0.5);
    else
      src := TToneSource.Create(osSine, 1000.0, 0.5);
    end;
    res := RenderSourceOffline(src, SR, 2, SR, 512);
  end;

  FxBegin('Advanced DSP: ' + cboAdvDspProcess.Text, 1, 4, memAdvDspReadout);
  try
  FxItem(1);
  FxStageDone(1, 'render ' + cboAdvDspSignal.Text);
  FxStage(2, 'measuring input level', 0);
  peakBefore := 0; rmsBefore := 0;
  for i := 0 to res.Frames - 1 do
  begin
    if Abs(res.Planar[0][i]) > peakBefore then peakBefore := Abs(res.Planar[0][i]);
    rmsBefore := rmsBefore + res.Planar[0][i] * res.Planar[0][i];
  end;
  if res.Frames > 0 then rmsBefore := Sqrt(rmsBefore / res.Frames);

  FxStageDone(2, 'measure input level');
  FxStage(3, 'running process', 0);
  readout := '';
  case cboAdvDspProcess.ItemIndex of
    0:
    begin   { Multiband compressor }
      mb := TMultibandCompressor.Create;
      try
        mb.Configure(SR, 2);
        mb.SetCrossovers(200, 2000);
        mb.SetBandParams(0, -30, 8, 3, 5, 80, 0);    // squash the low band hard
        mb.SetBandParams(1, -18, 2, 6, 10, 120, 0);
        mb.SetBandParams(2, -18, 2, 6, 10, 120, 0);
        SetLength(outBuf[0], res.Frames);
        SetLength(outBuf[1], res.Frames);
        mb.ProcessBlock([@res.Planar[0][0], @res.Planar[1][0]],
          [@outBuf[0][0], @outBuf[1][0]], res.Frames);
        peakAfter := 0; rmsAfter := 0;
        for i := 0 to res.Frames - 1 do
        begin
          if Abs(outBuf[0][i]) > peakAfter then peakAfter := Abs(outBuf[0][i]);
          rmsAfter := rmsAfter + outBuf[0][i] * outBuf[0][i];
        end;
        if res.Frames > 0 then rmsAfter := Sqrt(rmsAfter / res.Frames);
        readout := Format(
          'process: Multiband compressor'#13#10 +
          '--------------------------------------'#13#10 +
          'low band GR  : %6.2f dB'#13#10 +
          'mid band GR  : %6.2f dB'#13#10 +
          'high band GR : %6.2f dB'#13#10 +
          'peak in/out  : %6.2f / %6.2f dBFS'#13#10 +
          'RMS in/out   : %6.2f / %6.2f dBFS',
          [mb.BandGainReductionDb(0), mb.BandGainReductionDb(1), mb.BandGainReductionDb(2),
           SafeDb(peakBefore), SafeDb(peakAfter), SafeDb(rmsBefore), SafeDb(rmsAfter)]);
      finally
        mb.Free;
      end;
    end;
    1:
    begin   { Mastering chain }
      mc := TMasteringChain.Create;
      try
        mc.Configure(SR);
        mc.SetCeilingDb(-1.0);
        mc.SetTargetLufs(-14.0);
        mc.SetWidthAmount(1.0);
        SetLength(outBuf[0], res.Frames);
        SetLength(outBuf[1], res.Frames);
        mc.ProcessBlock([@res.Planar[0][0], @res.Planar[1][0]],
          [@outBuf[0][0], @outBuf[1][0]], res.Frames);
        peakAfter := 0;
        for i := 0 to res.Frames - 1 do
          if Abs(outBuf[0][i]) > peakAfter then peakAfter := Abs(outBuf[0][i]);
        readout := Format(
          'process: Mastering chain'#13#10 +
          '--------------------------------------'#13#10 +
          'ceiling         : -1.00 dBTP'#13#10 +
          'target loudness : -14.00 LUFS'#13#10 +
          'true peak (out) : %6.2f dBTP'#13#10 +
          'integrated LUFS : %6.2f LUFS'#13#10 +
          'peak in/out     : %6.2f / %6.2f dBFS',
          [mc.CurrentTruePeakDb, mc.CurrentIntegratedLufs, SafeDb(peakBefore), SafeDb(peakAfter)]);
      finally
        mc.Free;
      end;
    end;
    2:
    begin   { Time stretch }
      ratio := StrToFloatDef(edtAdvDspParam.Text, 2.0);
      ts := TPhaseVocoderStretch.Create;
      try
        ts.Process(res.Planar[0], ratio, stretched);
        readout := Format(
          'process: Time stretch x%.2f'#13#10 +
          '--------------------------------------'#13#10 +
          'input samples  : %d'#13#10 +
          'output samples : %d (estimate %d)',
          [ratio, res.Frames, Length(stretched), ts.EstimateOutputLength(res.Frames, ratio)]);
      finally
        ts.Free;
      end;
    end;
  else
    begin   { Pitch shift }
      ratio := StrToFloatDef(edtAdvDspParam.Text, 12.0);
      ps := TPitchShifter.Create;
      try
        ps.Process(res.Planar[0], ratio, SR, stretched);
        readout := Format(
          'process: Pitch shift %.1f semitones'#13#10 +
          '--------------------------------------'#13#10 +
          'input samples  : %d'#13#10 +
          'output samples : %d (estimate %d)',
          [ratio, res.Frames, Length(stretched), ps.EstimateOutputLength(res.Frames)]);
      finally
        ps.Free;
      end;
    end;
  end;

  FxStageDone(3, 'process');
  FxStage(4, 'building readout', 0);
  memAdvDspReadout.Lines.Text := readout;
  FxStageDone(4, 'readout');
  finally
    FxEnd;
  end;
end;

procedure TfrmMain.btnAdvDspRunClick(Sender: TObject);
begin
  RunAdvDspProcess;
end;

{ ---- AI (Phase 20): credential + MCP-server management over the foundation
       units. Phases 21-23 wire up live OpenAI, Claude and DeepSeek chat
       providers (via UDAW.AI.Providers.CreateAIProvider) for Test and the
       chat panel below; Suno (Phase 24) is a generation job, not a chat
       provider, so it has its own panel/button (btnSunoGenerateClick)
       instead of going through that factory. Phase 25's voice panel
       (btnVoiceRecordClick) sits below Suno's and either runs a built-in
       command or forwards the transcript into the same chat history. ---- }

procedure TfrmMain.RefreshAiTab;
const
  CFG_SEC_AI = 'ai';
  CFG_AI_SUNO_BASE_URL = 'suno_base_url';
var
  i: Integer;
  cfg: TMCPServerConfig;
begin
  if (App <> nil) and (App.Config <> nil) then
  begin
    chkSunoAdvanced.Checked := App.Config.GetBool('ai', 'suno_advanced', False);
    cboSunoApi.ItemIndex := EnsureRange(App.Config.GetInt('ai', 'suno_api_kind', 1), 0, 1);
    cboSunoApiChange(nil);
    edtSunoBaseUrl.Text := App.Config.GetString(CFG_SEC_AI, CFG_AI_SUNO_BASE_URL, edtSunoBaseUrl.Text);
    SetSunoModel(App.Config.GetString('ai', 'suno_model', SUNO_MANAGED_DEFAULT_MODEL));
    edtSunoCallback.Text := App.Config.GetString('ai', 'suno_callback_url', '');
    if not chkSunoAdvanced.Checked then ApplySunoAutoConfig;
    chkSunoCustomClick(nil);
    LoadSunoRefs;
  end;
  FAiMcpServers.Clear;
  for i := 0 to MCPServerRegistry.Count - 1 do
  begin
    cfg := MCPServerRegistry.GetConfig(i);
    if cfg.UseStdio then
      FAiMcpServers.Add(Format('%s  [stdio]  %s', [cfg.Name, cfg.CommandLine]))
    else
      FAiMcpServers.Add(Format('%s  [http]  %s', [cfg.Name, cfg.HttpEndpoint]));
  end;
  lstAiMcpServers.Items.Assign(FAiMcpServers);
  cboAiProviderChange(nil);
end;

procedure TfrmMain.cboAiProviderChange(Sender: TObject);
var
  pid, key: string;
  isSuno, isLuma: Boolean;
begin
  if (cboAiProvider.ItemIndex < 0) or (cboAiProvider.ItemIndex > High(AI_KNOWN_PROVIDERS)) then Exit;
  pid := AI_KNOWN_PROVIDERS[cboAiProvider.ItemIndex];
  if HasAIApiKey(pid) and GetAIApiKey(pid, key) then
    edtAiApiKey.Text := key
  else
    edtAiApiKey.Text := '';
  { The previous provider's models aren't valid for the new one - only an
    explicit/successful Test (btnAiTestClick) refetches the list, so no
    network call happens just from switching the combo. }
  cboAiModel.Items.Clear;
  cboAiModel.Text := '';
  FAiHistory := nil;

  { Adaptive layout: Suno is a generation job, not a chat provider (see the
    header comment above RefreshAiTab), so its whole panel plus the chat/
    model controls that don't apply to it are shown/hidden together rather
    than leaving every field visible regardless of provider. pnlAiChat and
    pnlAiSuno are alTop-aligned siblings inside the Generation tab, so hiding
    one automatically collapses its space and reflows the other - no manual
    repositioning needed. The Recordings and Lyrics/Styles tabs only apply to
    Suno, so they disappear entirely for a chat provider rather than sitting
    there empty. }
  isSuno := SameText(pid, 'suno');
  { Luma is video/image only (no music, lyrics, instrumental or sheet music
    in its API - see UDAW.AI.Luma), so it gets its own panel, and the
    music-only Recordings / Lyrics tabs and the chat controls are hidden. }
  isLuma := SameText(pid, 'luma');
  pnlAiSuno.Visible := isSuno;
  pnlAiLuma.Visible := isLuma;
  pnlAiChat.Visible := not (isSuno or isLuma);
  lblAiModel.Visible := not (isSuno or isLuma);
  cboAiModel.Visible := not (isSuno or isLuma);
  btnAiTest.Visible := not (isSuno or isLuma);
  tsAiRecordings.TabVisible := isSuno;
  tsAiLyrics.TabVisible := isSuno;
  if isLuma then cboLumaKindChange(nil);

  if isSuno and not chkSunoAdvanced.Checked then ApplySunoAutoConfig;

  TryAutoPopulateAiModelList(pid);
end;

procedure TfrmMain.cboAiModelChange(Sender: TObject);
const
  CFG_SEC_AI = 'ai';
  CFG_AI_MODEL_PREFIX = 'model.';
var
  pid: string;
begin
  { cboAiProviderChange clears Items + Text together when switching provider,
    which also fires this OnChange - skip persisting in that case, or the
    empty text would overwrite the new provider's remembered choice before
    the model list (and any remembered selection) is even loaded. }
  if cboAiModel.Items.Count = 0 then Exit;
  if (App = nil) or (App.Config = nil) then Exit;
  if (cboAiProvider.ItemIndex < 0) or (cboAiProvider.ItemIndex > High(AI_KNOWN_PROVIDERS)) then Exit;
  pid := AI_KNOWN_PROVIDERS[cboAiProvider.ItemIndex];
  App.Config.SetString(CFG_SEC_AI, CFG_AI_MODEL_PREFIX + pid, cboAiModel.Text);
end;

procedure TfrmMain.btnAiSaveClick(Sender: TObject);
var
  pid: string;
begin
  if (cboAiProvider.ItemIndex < 0) or (cboAiProvider.ItemIndex > High(AI_KNOWN_PROVIDERS)) then Exit;
  pid := AI_KNOWN_PROVIDERS[cboAiProvider.ItemIndex];
  SetAIApiKey(pid, edtAiApiKey.Text);
  AISecureLog.RegisterSecret(edtAiApiKey.Text);
  AISecureLog.Info('ui.ai', Format('saved API key for %s', [AIProviderDisplayName(pid)]));
  memAiLog.Lines.Add(Format('Saved API key for %s.', [AIProviderDisplayName(pid)]));

  { The key just saved may be new/changed, so refresh the model list against
    it right away rather than waiting for a provider switch (the other
    trigger for this) or an explicit Test. }
  TryAutoPopulateAiModelList(pid);
end;

{ Shared by btnAiTestClick and the auto-populate-on-provider-switch/key-save
  paths below: fetches AProvider's model list and refills cboAiModel from it,
  restoring whichever model was last remembered for this provider (or index 0
  if none/no longer offered). Returns False (leaving cboAiModel untouched) on
  an empty/failed fetch, which is never treated as fatal by any caller - the
  user's current selection (or the hardcoded default) just stays put. }
function TfrmMain.PopulateAiModelList(const APid, AKey: string): Boolean;
const
  CFG_SEC_AI = 'ai';
  CFG_AI_MODEL_PREFIX = 'model.';
var
  provider: IAIProvider;
  models: TArray<string>;
  rememberedModel: string;
  i, pickIndex: Integer;
begin
  Result := False;
  provider := CreateAIProvider(APid, AKey);
  if provider = nil then Exit;
  try
    models := provider.ListModels;
  except
    models := nil;
  end;
  if Length(models) = 0 then Exit;

  rememberedModel := '';
  if (App <> nil) and (App.Config <> nil) then
    rememberedModel := App.Config.GetString(CFG_SEC_AI, CFG_AI_MODEL_PREFIX + APid, '');
  cboAiModel.Items.Clear;
  for i := 0 to High(models) do
    cboAiModel.Items.Add(models[i]);
  pickIndex := -1;
  if rememberedModel <> '' then
    pickIndex := cboAiModel.Items.IndexOf(rememberedModel);
  if pickIndex < 0 then
    pickIndex := 0;
  cboAiModel.ItemIndex := pickIndex;
  Result := True;
end;

{ Auto-populate-on-key-present path (cboAiProviderChange, btnAiSaveClick): a
  key is trusted to be good the moment it's stored, so the model list can be
  fetched right away instead of making the user run Test first just to see
  what's available to pick from. }
procedure TfrmMain.TryAutoPopulateAiModelList(const APid: string);
begin
  if SameText(APid, 'suno') or SameText(APid, 'luma') or (edtAiApiKey.Text = '') then Exit;
  Screen.Cursor := crHourGlass;
  ShowStatusBusy(Format('Fetching %s model list...', [AIProviderDisplayName(APid)]));
  try
    if PopulateAiModelList(APid, edtAiApiKey.Text) then
      memAiLog.Lines.Add(Format('%s: fetched %d model(s).', [AIProviderDisplayName(APid), cboAiModel.Items.Count]))
    else
      memAiLog.Lines.Add(Format('%s: could not fetch model list yet - use Test to verify the key.', [AIProviderDisplayName(APid)]));
  finally
    HideStatusProgress;
    Screen.Cursor := crDefault;
  end;
end;

procedure TfrmMain.cboLumaKindChange(Sender: TObject);
var
  kind: TLumaMediaKind;
  caps: TLumaCapabilities;
  i: Integer;
begin
  if cboLumaKind.ItemIndex = 1 then kind := lmkImage else kind := lmkVideo;
  caps := LumaCapabilities(kind);
  cboLumaModel.Items.Clear;
  for i := 0 to High(caps.Models) do cboLumaModel.Items.Add(caps.Models[i]);
  cboLumaModel.ItemIndex := 0;
  lblLumaAspect.Visible := caps.AspectRatio;
  cboLumaAspect.Visible := caps.AspectRatio;
  lblLumaResolution.Visible := caps.Resolution;
  cboLumaResolution.Visible := caps.Resolution;
  lblLumaDuration.Visible := caps.Duration;
  cboLumaDuration.Visible := caps.Duration;
  chkLumaLoop.Visible := caps.Loop;
  lblLumaStartFrame.Visible := caps.Keyframes;
  edtLumaStartFrame.Visible := caps.Keyframes;
  lblLumaEndFrame.Visible := caps.Keyframes;
  edtLumaEndFrame.Visible := caps.Keyframes;
  lblLumaImageRef.Visible := caps.ImageRef;
  edtLumaImageRef.Visible := caps.ImageRef;
  lblLumaImageRefWeight.Visible := caps.ImageRef;
  edtLumaImageRefWeight.Visible := caps.ImageRef;
  lblLumaStyleRef.Visible := caps.StyleRef;
  edtLumaStyleRef.Visible := caps.StyleRef;
  edtLumaStyleWeight.Visible := caps.StyleRef;
  lblLumaCharRef.Visible := caps.CharacterRef;
  edtLumaCharRef.Visible := caps.CharacterRef;
  lblLumaModifyRef.Visible := caps.ModifyRef;
  edtLumaModifyRef.Visible := caps.ModifyRef;
  edtLumaModifyWeight.Visible := caps.ModifyRef;
  { Video rows end at End frame; image rows run to Modify image - size the
    panel to what is visible so the buttons sit right under the last row. }
  lblLumaConcepts.Visible := caps.Concepts;
  lstLumaConcepts.Visible := caps.Concepts;
  btnLumaConcepts.Visible := caps.Concepts;
  lblLumaFormat.Visible := caps.Format;
  cboLumaFormat.Visible := caps.Format;
end;

procedure TfrmMain.btnLumaTestClick(Sender: TObject);
var
  client: TLumaClient;
  cents: Double;
begin
  if not RequireRegistration('Testing an AI provider') then Exit;
  if edtAiApiKey.Text = '' then
  begin
    memAiLog.Lines.Add('Luma: no key entered.');
    Exit;
  end;
  Screen.Cursor := crHourGlass;
  ShowStatusBusy('Testing Luma connection...');
  client := TLumaClient.Create(edtAiApiKey.Text);
  try
    try
      cents := client.GetCreditsCents;
      memAiLog.Lines.Add(Format('Luma: key OK, credit balance $%.2f.', [cents / 100]));
    except
      on E: Exception do
        memAiLog.Lines.Add('Luma: ' + AISecureLog.Redact(E.Message));
    end;
  finally
    client.Free;
    HideStatusProgress;
    Screen.Cursor := crDefault;
  end;
end;

{ "Music Tabular Only": Luma has no music service, so this never calls Luma.
  The prompt goes to a text provider the user already has a key for, and the
  fixed-width tab it returns is rendered to a PDF under
  <Recordings>\AI\Rendered so it can be printed/studied. }
procedure TfrmMain.GenerateMusicTabPdf;
const
  CFG_SEC_AI = 'ai';
  CFG_AI_MODEL_PREFIX = 'model.';
  TEXT_PROVIDERS: array[0..2] of string = ('claude', 'openai', 'deepseek');
var
  prompt, pid, key, model, path: string;
  i: Integer;
  provider: IAIProvider;
  msg: TAIMessage;
  req: TAIRequest;
  resp: TAIResponse;
begin
  prompt := Trim(edtLumaPrompt.Text);
  if prompt = '' then
  begin
    memAiLog.Lines.Add('Music tab: describe the music (song, instrument, style, level) in the prompt box first.');
    Exit;
  end;
  pid := '';
  for i := Low(TEXT_PROVIDERS) to High(TEXT_PROVIDERS) do
    if HasAIApiKey(TEXT_PROVIDERS[i]) and GetAIApiKey(TEXT_PROVIDERS[i], key) and (key <> '') then
    begin
      pid := TEXT_PROVIDERS[i];
      Break;
    end;
  if pid = '' then
  begin
    memAiLog.Lines.Add('Music tab: needs a Claude, OpenAI or DeepSeek key (Luma cannot write music). Save one on the AI Selection tab.');
    Exit;
  end;
  provider := CreateAIProvider(pid, key);
  if provider = nil then
  begin
    memAiLog.Lines.Add('Music tab: no live provider available for ' + AIProviderDisplayName(pid) + '.');
    Exit;
  end;
  model := App.Config.GetString(CFG_SEC_AI, CFG_AI_MODEL_PREFIX + pid, '');
  if model = '' then
    if pid = 'claude' then model := 'claude-sonnet-5'
    else if pid = 'openai' then model := 'gpt-4o-mini'
    else model := 'deepseek-chat';

  msg.Role := arUser;
  msg.Content := MusicTabSystemPrompt + sLineBreak + sLineBreak + 'Request: ' + prompt;
  req.Messages := [msg];
  req.Model := model;
  req.Temperature := 0.4;
  req.MaxTokens := 4000;
  req.Stream := False;

  Screen.Cursor := crHourGlass;
  ShowStatusBusy(Format('Writing music tab with %s...', [AIProviderDisplayName(pid)]));
  try
    try
      resp := provider.SendMessage(req, nil);
      UpdateStatusProgress(0, 'Rendering PDF...');
      path := MusicTabToPdf(RecordingRootPath, prompt, resp.Content);
      FLumaLastResult := path;
      btnLumaOpen.Enabled := True;
      memAiLog.Lines.Add(Format('Music tab: written by %s, saved %s', [AIProviderDisplayName(pid), path]));
    except
      on E: Exception do
        memAiLog.Lines.Add('Music tab FAILED: ' + AISecureLog.Redact(E.Message));
    end;
  finally
    HideStatusProgress;
    Screen.Cursor := crDefault;
  end;
end;

procedure TfrmMain.btnLumaGenerateClick(Sender: TObject);
var
  req: TLumaRequest;
  i: Integer;
begin
  if not RequireRegistration('AI video/image generation (Luma)') then Exit;
  if chkLumaTabOnly.Checked then
  begin
    GenerateMusicTabPdf;
    Exit;
  end;
  if FLumaJob <> nil then Exit;
  if edtAiApiKey.Text = '' then
  begin
    memAiLog.Lines.Add('Luma: enter and Save your API key first.');
    Exit;
  end;
  req := Default(TLumaRequest);
  if cboLumaKind.ItemIndex = 1 then req.Kind := lmkImage else req.Kind := lmkVideo;
  req.Model := cboLumaModel.Text;
  req.Prompt := Trim(edtLumaPrompt.Text);
  req.AspectRatio := cboLumaAspect.Text;
  if req.Kind = lmkVideo then
  begin
    req.Resolution := cboLumaResolution.Text;
    req.Duration := cboLumaDuration.Text;
    req.Loop := chkLumaLoop.Checked;
    req.StartFrameUrl := Trim(edtLumaStartFrame.Text);
    req.EndFrameUrl := Trim(edtLumaEndFrame.Text);
    for i := 0 to lstLumaConcepts.Count - 1 do
      if lstLumaConcepts.Selected[i] then
      begin
        SetLength(req.Concepts, Length(req.Concepts) + 1);
        req.Concepts[High(req.Concepts)] := lstLumaConcepts.Items[i];
      end;
  end
  else
  begin
    req.ImageFormat := cboLumaFormat.Text;
    req.ImageRefUrl := Trim(edtLumaImageRef.Text);
    req.ImageRefWeight := StrToFloatDef(Trim(edtLumaImageRefWeight.Text), -1, TFormatSettings.Invariant);
    req.StyleRefUrl := Trim(edtLumaStyleRef.Text);
    req.StyleRefWeight := StrToFloatDef(Trim(edtLumaStyleWeight.Text), -1, TFormatSettings.Invariant);
    req.CharacterRefUrl := Trim(edtLumaCharRef.Text);
    req.ModifyRefUrl := Trim(edtLumaModifyRef.Text);
    req.ModifyRefWeight := StrToFloatDef(Trim(edtLumaModifyWeight.Text), -1, TFormatSettings.Invariant);
  end;
  try
    FLumaJob := TLumaGenerationJob.Create(edtAiApiKey.Text, req, RecordingRootPath);
    FTrackedJobs.Add(FLumaJob);
    App.Jobs.Submit(FLumaJob, False);
    memAiLog.Lines.Add('Luma: generation queued. Progress is in the status bar and Jobs tab. Cancel stops local work; Luma may still charge.');
  except
    on E: Exception do
    begin
      if FLumaJob <> nil then
      begin
        FTrackedJobs.Remove(FLumaJob);
        FreeAndNil(FLumaJob);
      end;
      memAiLog.Lines.Add('Luma: ' + AISecureLog.Redact(E.Message));
    end;
  end;
end;

procedure TfrmMain.btnLumaConceptsClick(Sender: TObject);
var
  client: TLumaClient;
  keys: TArray<string>;
  k: string;
begin
  if edtAiApiKey.Text = '' then
  begin
    memAiLog.Lines.Add('Luma: enter and Save your API key first.');
    Exit;
  end;
  Screen.Cursor := crHourGlass;
  ShowStatusBusy('Fetching Luma camera concepts...');
  client := TLumaClient.Create(edtAiApiKey.Text);
  try
    try
      keys := client.GetConcepts;
      lstLumaConcepts.Items.BeginUpdate;
      try
        lstLumaConcepts.Items.Clear;
        for k in keys do lstLumaConcepts.Items.Add(k);
      finally
        lstLumaConcepts.Items.EndUpdate;
      end;
      memAiLog.Lines.Add(Format('Luma: %d camera concept(s) loaded.', [Length(keys)]));
    except
      on E: Exception do memAiLog.Lines.Add('Luma: ' + AISecureLog.Redact(E.Message));
    end;
  finally
    client.Free;
    HideStatusProgress;
    Screen.Cursor := crDefault;
  end;
end;

procedure TfrmMain.btnLumaOpenClick(Sender: TObject);
begin
  if (FLumaLastResult <> '') and FileExists(FLumaLastResult) then
    ShellExecute(0, 'open', PChar(FLumaLastResult), nil, nil, SW_SHOWNORMAL)
  else
    memAiLog.Lines.Add('Luma: no generated result to open yet.');
end;

procedure TfrmMain.btnLumaCancelClick(Sender: TObject);
begin
  if FLumaJob <> nil then FLumaJob.Cancel;
end;

procedure TfrmMain.FinishLumaJob;
var
  job: TLumaGenerationJob;
  src: TMediaSource;
  cmd: TAddTimelineClipCommand;
  trackId: Integer;
begin
  if (FLumaJob = nil) or not FLumaJob.IsTerminal then Exit;
  job := FLumaJob;
  FLumaJob := nil; // consume once; tracked jobs keep ownership until shutdown
  if job.Status <> jsSucceeded then
  begin
    memAiLog.Lines.Add('Luma: ' + JobStatusName(job.Status) + ' ' + AISecureLog.Redact(job.ErrorMessage));
    Exit;
  end;
  FLumaLastResult := job.OutputPath;
  btnLumaOpen.Enabled := True;
  memAiLog.Lines.Add('Luma: saved ' + job.OutputPath);
  if job.IsVideo and (FProject <> nil) then
  try
    trackId := TlNewVideoTrackId;
    src := FProject.Timeline.AddSource(job.OutputPath, 1000, 1,
      Round(job.DurationSeconds * 1000), mkVideoFile);
    cmd := TAddTimelineClipCommand.Create(FProject, trackId, src.Id,
      ChangeFileExt(ExtractFileName(job.OutputPath), ''),
      FTlView.Snap(FProject.Timeline.PlayheadSeconds), 0, job.DurationSeconds);
    FCmds.Perform(cmd);
    FTlSelClipId := cmd.CreatedId;
    RefreshTimelineTab;
    memAiLog.Lines.Add('Luma: video placed on a VIDEO channel of the Timeline.');
  except
    on E: Exception do memAiLog.Lines.Add('Luma timeline import failed: ' + E.Message);
  end;
end;

procedure TfrmMain.btnAiTestClick(Sender: TObject);
var
  pid, key: string;
  provider: IAIProvider;
  req: TAIRequest;
  resp: TAIResponse;
  msg: TAIMessage;
begin
  if not RequireRegistration('Testing an AI provider') then Exit;
  if (cboAiProvider.ItemIndex < 0) or (cboAiProvider.ItemIndex > High(AI_KNOWN_PROVIDERS)) then Exit;
  pid := AI_KNOWN_PROVIDERS[cboAiProvider.ItemIndex];
  if not (HasAIApiKey(pid) and GetAIApiKey(pid, key) and (key <> '')) then
  begin
    memAiLog.Lines.Add(Format('%s: no key stored.', [AIProviderDisplayName(pid)]));
    Exit;
  end;

  provider := CreateAIProvider(pid, key);
  if provider = nil then
  begin
    memAiLog.Lines.Add(Format('%s: a key is stored (no live provider is wired up yet to test it against).', [AIProviderDisplayName(pid)]));
    Exit;
  end;

  msg.Role := arUser;
  msg.Content := 'Reply with exactly the word: OK';
  req.Messages := [msg];
  req.Model := cboAiModel.Text;
  req.Temperature := 0;
  req.MaxTokens := 16;
  req.Stream := False;

  Screen.Cursor := crHourGlass;
  ShowStatusBusy(Format('Testing %s connection...', [AIProviderDisplayName(pid)]));
  try
    try
      resp := provider.SendMessage(req, nil);
      memAiLog.Lines.Add(Format('%s: connection OK - reply: %s', [AIProviderDisplayName(pid), resp.Content]));

      { On a successful Test, (re)fetch the provider's model list so the user
        can pick a real model instead of only ever using the hardcoded
        default or whatever was already loaded. }
      UpdateStatusProgress(0, Format('%s: fetching model list...', [AIProviderDisplayName(pid)]));
      if PopulateAiModelList(pid, key) then
        memAiLog.Lines.Add(Format('%s: fetched %d model(s).', [AIProviderDisplayName(pid), cboAiModel.Items.Count]))
      else
        memAiLog.Lines.Add(Format('%s: could not fetch model list (keeping current selection).', [AIProviderDisplayName(pid)]));
    except
      on E: Exception do
        memAiLog.Lines.Add(Format('%s: test FAILED - %s', [AIProviderDisplayName(pid), E.Message]));
    end;
  finally
    HideStatusProgress;
    Screen.Cursor := crDefault;
  end;
end;

procedure TfrmMain.btnAiDeleteClick(Sender: TObject);
var
  pid: string;
begin
  if (cboAiProvider.ItemIndex < 0) or (cboAiProvider.ItemIndex > High(AI_KNOWN_PROVIDERS)) then Exit;
  pid := AI_KNOWN_PROVIDERS[cboAiProvider.ItemIndex];
  DeleteAIApiKey(pid);
  edtAiApiKey.Text := '';
  AISecureLog.Info('ui.ai', Format('deleted API key for %s', [AIProviderDisplayName(pid)]));
  memAiLog.Lines.Add(Format('Deleted API key for %s.', [AIProviderDisplayName(pid)]));
end;

procedure TfrmMain.btnAiMcpAddClick(Sender: TObject);
var
  cfg: TMCPServerConfig;
  cmdOrUrl: string;
begin
  if Trim(edtAiMcpName.Text) = '' then
  begin
    memAiLog.Lines.Add('MCP server needs a name.');
    Exit;
  end;
  cfg := TMCPServerConfig.Default(Trim(edtAiMcpName.Text));
  cmdOrUrl := Trim(edtAiMcpCommand.Text);
  if StartsText('http://', cmdOrUrl) or StartsText('https://', cmdOrUrl) then
  begin
    cfg.UseStdio := False;
    cfg.HttpEndpoint := cmdOrUrl;
    if Trim(edtAiMcpToken.Text) <> '' then
    begin
      { bearer token goes to the OS secure store, keyed by server name - never the registry file }
      SetMCPClientToken(cfg.Name, Trim(edtAiMcpToken.Text));
      edtAiMcpToken.Text := '';
    end;
  end
  else
  begin
    cfg.UseStdio := True;
    cfg.CommandLine := cmdOrUrl;
  end;
  try
    MCPServerRegistry.Add(cfg);
  except
    on E: EUDAWError do
    begin
      memAiLog.Lines.Add('MCP: ' + E.Message);
      Exit;
    end;
  end;
  MCPServerRegistry.Save;
  AISecureLog.Info('ui.ai', Format('added MCP server "%s"', [cfg.Name]));
  memAiLog.Lines.Add(Format('Added MCP server "%s" (%s).',
    [cfg.Name, IfThen(cfg.UseStdio, 'stdio', 'http')]));
  RefreshAiTab;
end;

procedure TfrmMain.btnAiMcpRemoveClick(Sender: TObject);
var
  nm: string;
begin
  if lstAiMcpServers.ItemIndex < 0 then Exit;
  if lstAiMcpServers.ItemIndex >= MCPServerRegistry.Count then Exit;
  nm := MCPServerRegistry.GetConfig(lstAiMcpServers.ItemIndex).Name;
  MCPServerRegistry.Remove(nm);
  MCPServerRegistry.Save;
  memAiLog.Lines.Add(Format('Removed MCP server "%s".', [nm]));
  RefreshAiTab;
end;

procedure TfrmMain.btnAiMcpTestClick(Sender: TObject);
var
  cfg: TMCPServerConfig;
  transport: IMCPTransport;
  stdio: TMCPStdioTransport;
  http: TMCPHttpTransport;
  client: IMCPClient;
  tools: TArray<TMCPToolInfo>;
  i: Integer;
  tok: string;
begin
  if not RequireRegistration('Testing an MCP server') then Exit;
  if lstAiMcpServers.ItemIndex < 0 then
  begin
    memAiLog.Lines.Add('MCP: select a server in the list to test.');
    Exit;
  end;
  if lstAiMcpServers.ItemIndex >= MCPServerRegistry.Count then Exit;
  cfg := MCPServerRegistry.GetConfig(lstAiMcpServers.ItemIndex);

  Screen.Cursor := crHourGlass;
  try
    try
      if cfg.UseStdio then
      begin
        stdio := TMCPStdioTransport.Create;
        stdio.CommandLine := cfg.CommandLine;
        if cfg.TimeoutMs > 0 then stdio.TimeoutMs := cfg.TimeoutMs;
        transport := stdio;
      end
      else
      begin
        http := TMCPHttpTransport.Create;
        http.Endpoint := cfg.HttpEndpoint;
        if GetMCPClientToken(cfg.Name, tok) then
          http.BearerToken := tok;
        transport := http;
      end;
      transport.Start;
      client := TMCPClient.Create;
      if not client.Initialize(transport) then
      begin
        memAiLog.Lines.Add(Format('MCP "%s": server did not respond to initialize.', [cfg.Name]));
        Exit;
      end;
      tools := client.ListToolsDetailed;
      memAiLog.Lines.Add(Format('MCP "%s": connected (%s %s) - %d tool(s):',
        [cfg.Name, client.Capabilities.ServerName, client.Capabilities.ServerVersion, Length(tools)]));
      for i := 0 to High(tools) do
        memAiLog.Lines.Add('  - ' + tools[i].Name + IfThen(tools[i].Description <> '', ': ' + tools[i].Description, ''));
    except
      on E: Exception do
        memAiLog.Lines.Add(Format('MCP "%s": test FAILED - %s', [cfg.Name, E.Message]));
    end;
  finally
    if transport <> nil then
      try transport.Stop; except end;
    Screen.Cursor := crDefault;
  end;
end;

function TfrmMain.McpServerGetDoc: TProjectDocument;
begin
  Result := FProject;
end;

function TfrmMain.McpServerGetCommands: TCommandManager;
begin
  Result := FCmds;
end;

{ MCP worker threads call this; the live Timeline player is VCL-owned, so the
  action is marshalled onto the main thread. }
function TfrmMain.McpServerTransport(const AAction: string; AFromBeginning: Boolean): string;
var
  act: string;
  fromStart: Boolean;
begin
  act := AAction;
  fromStart := AFromBeginning;
  TThread.Synchronize(nil,
    procedure
    begin
      if act = 'play' then
        StartTimelinePlayback(fromStart, False, False)
      else
      begin
        StopTimelinePlayback;
        RefreshTimelineTab;
      end;
    end);
  if act = 'play' then Result := 'timeline playback started' else Result := 'timeline playback stopped';
end;

procedure TfrmMain.chkAiMcpExposeClick(Sender: TObject);
begin
  if chkAiMcpExpose.Checked and not RequireRegistration('The MCP server (AI tool access)') then
  begin
    chkAiMcpExpose.Checked := False;
    Exit;
  end;
  if chkAiMcpExpose.Checked then
  begin
    if FMcpServer = nil then
      FMcpServer := TUDAWMcpServer.Create;
    FMcpServer.Port := StrToIntDef(Trim(edtAiMcpExposePort.Text), 8765);
    FMcpServer.BindAddress := IfThen(Trim(edtAiMcpBind.Text) = '', '127.0.0.1', Trim(edtAiMcpBind.Text));
    FMcpServer.AllowDestructive := chkAiMcpAllowDestructive.Checked;
    FMcpServer.OnGetDoc := McpServerGetDoc;
    FMcpServer.OnGetCommands := McpServerGetCommands;
    FMcpServer.OnGetBrowserRoots := GetAiBrowserRoots;
    FMcpServer.OnTransport := McpServerTransport;
    FMcpServer.AuthToken := EnsureMCPServerToken;   // clients must send 'Authorization: Bearer <token>'
    { Remote (outside-LAN) access: an https listener alongside the local one. }
    if chkAiMcpTls.Checked then
    begin
      FMcpServer.TlsPort := StrToIntDef(Trim(edtAiMcpTlsPort.Text), 8766);
      FMcpServer.TlsBindAddress := '0.0.0.0';
      FMcpServer.TlsCertFile := Trim(edtAiMcpCert.Text);
      FMcpServer.TlsKeyFile := Trim(edtAiMcpKey.Text);
    end
    else
      FMcpServer.TlsPort := 0;
    try
      FMcpServer.Start;
      memAiLog.Lines.Add('MCP server bearer token (give this to the MCP client): ' + FMcpServer.AuthToken);
      { BindAddress may be 0.0.0.0/a LAN IP as well as loopback - see the
        edtAiMcpBind hint: reaching this from outside the machine is then a
        matter of routing + the OS firewall, same as any other listening
        service, not something this server enforces itself. }
      memAiLog.Lines.Add(Format('MCP server exposing UDAW on %s:%d (destructive tools %s).',
        [FMcpServer.BindAddress, FMcpServer.Port, IfThen(FMcpServer.AllowDestructive, 'allowed', 'blocked')]));
      if FMcpServer.IsTlsRunning then
        memAiLog.Lines.Add(Format('MCP HTTPS listener on port %d (TLS 1.2+, bearer token required). ' +
          'Forward this port / start a tunnel, then use "Test TLS / URL" with your public https URL.',
          [FMcpServer.TlsPort]));
    except
      on E: Exception do
      begin
        memAiLog.Lines.Add('MCP server FAILED to start: ' + E.Message);
        chkAiMcpExpose.Checked := False;
      end;
    end;
  end
  else if FMcpServer <> nil then
  begin
    FMcpServer.Stop;
    memAiLog.Lines.Add('MCP server stopped.');
  end;
end;

procedure TfrmMain.RunMcpDiagnostic(const AUrl: string);
var
  r: TMCPDiagResult;
  tok: string;
  ln: string;
begin
  if not RequireRegistration('Testing the MCP connection') then Exit;
  tok := '';
  if FMcpServer <> nil then tok := FMcpServer.AuthToken;
  if tok = '' then tok := EnsureMCPServerToken;
  memAiLog.Lines.Add('MCP connectivity test: ' + AUrl);
  ShowStatusProgress('Testing MCP connection...', 0);
  Screen.Cursor := crHourGlass;
  try
    r := MCPTestEndpoint(AUrl, tok, chkAiMcpSelfSigned.Checked, 10000);
  finally
    Screen.Cursor := crDefault;
    HideStatusProgress;
  end;
  for ln in r.Report.Split([sLineBreak]) do
    memAiLog.Lines.Add('  ' + ln);
end;

procedure TfrmMain.btnAiMcpTestLocalClick(Sender: TObject);
begin
  if (FMcpServer = nil) or not FMcpServer.IsRunning then
  begin
    memAiLog.Lines.Add('MCP: tick "Expose UDAW as an MCP server" first, then test.');
    Exit;
  end;
  RunMcpDiagnostic(Format('http://127.0.0.1:%d/mcp', [FMcpServer.Port]));
end;

procedure TfrmMain.btnAiMcpTestTlsClick(Sender: TObject);
var
  url: string;
begin
  url := Trim(edtAiMcpTestUrl.Text);
  if url = '' then
  begin
    if (FMcpServer = nil) or not FMcpServer.IsTlsRunning then
    begin
      memAiLog.Lines.Add('MCP: enter the public https URL to test, or tick HTTPS (TLS) and expose the server first.');
      Exit;
    end;
    url := Format('https://127.0.0.1:%d/mcp', [FMcpServer.TlsPort]);
  end;
  RunMcpDiagnostic(url);
end;

procedure TfrmMain.LogAiToolResult(const AText: string);
begin
  memAiLog.Lines.Add('  [tool] ' + AText);
end;

procedure TfrmMain.SendAiChatPrompt(const APrompt: string; ABatchConfirm: Boolean);
const
  { Phase 26 follow-up: a full arrangement reply routinely needs more than one
    model turn - either because a single reply got cut off mid-plan (finish
    reason "max_tokens"/"length") or because the model spent its whole first
    turn on discovery calls (FindSample etc.) and needs a nudge, with those
    results in hand, to actually emit the mutating AddTrack/SetTempo/
    AddSampleToTimeline calls. 20 rounds is a generous ceiling so a big
    arrangement (many tracks/clips) can complete over several turns without
    looping forever if the model never converges. }
  MAX_AI_ROUNDS = 20;
var
  pid, key: string;
  provider: IAIProvider;
  req: TAIRequest;
  resp: TAIResponse;
  msg: TAIMessage;
  dispatcher: TAIToolDispatcher;
  calls: TArray<TAIToolCall>;
  mcpCalls: TArray<TMCPToolCallRequest>;
  i, destructiveCount, round: Integer;
  errMsg, resultText, mcpFragment, confirmList, roundResultsLog: string;
  batchAllowed, truncated, hadMutatingCall, keepGoing, sawTrackOrSampleTool, placedSampleEver, execOk: Boolean;
begin
  if not RequireRegistration('AI chat') then Exit;
  if (cboAiProvider.ItemIndex < 0) or (cboAiProvider.ItemIndex > High(AI_KNOWN_PROVIDERS)) then Exit;
  pid := AI_KNOWN_PROVIDERS[cboAiProvider.ItemIndex];

  if Trim(APrompt) = '' then Exit;

  if not (HasAIApiKey(pid) and GetAIApiKey(pid, key) and (key <> '')) then
  begin
    memAiLog.Lines.Add(Format('%s: no API key stored - save one first.', [AIProviderDisplayName(pid)]));
    Exit;
  end;

  provider := CreateAIProvider(pid, key);
  if provider = nil then
  begin
    memAiLog.Lines.Add(Format('%s: no live integration yet.', [AIProviderDisplayName(pid)]));
    Exit;
  end;

  { Phase 26: the model is told the tool vocabulary once, as the first system
    message, so its replies can carry a fenced ```tool block instead of only
    describing an action in prose. The MCP bridge is refreshed alongside it
    (so newly added/edited MCP servers in the registry are picked up per
    conversation) and its fragment - if any server actually has tools -
    is appended to the same system message. }
  if Length(FAiHistory) = 0 then
  begin
    if FMcpBridge <> nil then
    begin
      FMcpBridge.RefreshAll;
      mcpFragment := FMcpBridge.BuildSystemPromptFragment;
    end
    else
      mcpFragment := '';
    msg.Role := arSystem;
    if mcpFragment <> '' then
      msg.Content := AIToolSystemPrompt + sLineBreak + sLineBreak + mcpFragment
    else
      msg.Content := AIToolSystemPrompt;
    FAiHistory := [msg];
  end;

  msg.Role := arUser;
  msg.Content := Trim(APrompt);
  FAiHistory := FAiHistory + [msg];
  memAiLog.Lines.Add('You: ' + Trim(APrompt));

  req.Model := cboAiModel.Text;
  req.Temperature := 0.7;
  { A full arrangement reply (plan prose + a FindSample/AddTrack/
    AddSampleToTimeline tool block per clip - dozens of them for a ~3 minute
    tune) does not fit in 1024 tokens: the model's reply gets cut off
    mid-JSON, ParseAIToolCalls finds no closing fence for the last block, and
    the whole batch silently did nothing even though the HTTP call itself
    succeeded. Give the batch-generation flow a much larger budget; ordinary
    chat replies (single tool call at most) keep the smaller one. On top of
    that, drive up to MAX_AI_ROUNDS request/response rounds below, so a
    cut-off reply - or a reply that only did discovery calls (FindSample/
    GetProjectInfo/...) and stopped there - gets automatically continued
    instead of leaving the arrangement half-built with no explanation. }
  if ABatchConfirm then
    req.MaxTokens := 16384
  else
    req.MaxTokens := 1024;
  req.Stream := False;

  Screen.Cursor := crHourGlass;
  try
    try
      round := 0;
      keepGoing := True;
      placedSampleEver := False;
      while keepGoing do
      begin
        Inc(round);
        keepGoing := False;
        req.Messages := FAiHistory;
        ShowStatusBusy(Format('Waiting for %s (round %d/%d)...', [AIProviderDisplayName(pid), round, MAX_AI_ROUNDS]));

        resp := provider.SendMessage(req, nil);
        memAiLog.Lines.Add(AIProviderDisplayName(pid) + ': ' + resp.Content);
        msg.Role := arAssistant;
        msg.Content := resp.Content;
        FAiHistory := FAiHistory + [msg];

        truncated := SameText(resp.FinishReason, 'max_tokens') or SameText(resp.FinishReason, 'length');
        roundResultsLog := '';
        hadMutatingCall := False;
        sawTrackOrSampleTool := False;

        { Phase 26: execute any structured tool calls the reply carried. Every
          mutating tool goes through FCmds (undo-safe); destructive ones ask
          for confirmation first, per plan section 35 - either one-by-one (the
          normal chat panel) or, when ABatchConfirm is set (the "Generate Tune
          from Browser Library" flow, which can carry dozens of AddTrack/
          AddSampleToTimeline calls for a single arrangement), as a single
          up-front summary so the user isn't clicking through a confirmation
          dialog per clip. }
        if FProject <> nil then
        begin
          calls := ParseAIToolCalls(resp.Content);
          if (Length(calls) = 0) and ABatchConfirm and not truncated then
            memAiLog.Lines.Add(Format(
              'No tool calls applied: the reply (%d character(s), finish reason "%s") ' +
              'contained no valid ```tool blocks.', [Length(resp.Content), resp.FinishReason]));
          if Length(calls) > 0 then
          begin
            batchAllowed := True;
            if ABatchConfirm then
            begin
              destructiveCount := 0;
              confirmList := '';
              for i := 0 to High(calls) do
                if IsDestructiveTool(calls[i].Kind) then
                begin
                  Inc(destructiveCount);
                  if destructiveCount <= 20 then
                    confirmList := confirmList + '  - ' + AIToolKindId(calls[i].Kind) + sLineBreak;
                end;
              if destructiveCount > 0 then
              begin
                batchAllowed := MessageDlg(Format(
                  'The AI wants to make %d change(s) to build this arrangement:' + sLineBreak + sLineBreak +
                  '%s' + IfThen(destructiveCount > 20, '  ... and ' + IntToStr(destructiveCount - 20) + ' more' + sLineBreak, '') +
                  sLineBreak + 'Apply all of them?',
                  [destructiveCount, confirmList]), mtConfirmation, [mbYes, mbNo], 0) = mrYes;
                if not batchAllowed then
                  LogAiToolResult(Format('all %d change(s) declined by user', [destructiveCount]));
              end;
            end;

            if batchAllowed then
            begin
              ShowStatusProgress('Applying AI actions...', Length(calls));
              dispatcher := TAIToolDispatcher.Create(FProject, FCmds);
              try
                dispatcher.OnGetBrowserRoots := GetAiBrowserRoots;
                for i := 0 to High(calls) do
                begin
                  UpdateStatusProgress(i + 1, Format('Applying %s (%d/%d)...',
                    [AIToolKindId(calls[i].Kind), i + 1, Length(calls)]));
                  if not IsReadOnlyTool(calls[i].Kind) then
                    hadMutatingCall := True;
                  if calls[i].Kind in [atkAddTrack, atkFindSample, atkAddSampleToTimeline] then
                    sawTrackOrSampleTool := True;
                  if not ValidateToolCall(calls[i], errMsg) then
                  begin
                    LogAiToolResult(Format('rejected %s: %s', [AIToolKindId(calls[i].Kind), errMsg]));
                    roundResultsLog := roundResultsLog + Format('  - %s: rejected (%s)', [AIToolKindId(calls[i].Kind), errMsg]) + sLineBreak;
                    Continue;
                  end;
                  if IsDestructiveTool(calls[i].Kind) and not ABatchConfirm then
                    if MessageDlg(Format('The AI wants to run %s. Allow it?', [AIToolKindId(calls[i].Kind)]),
                      mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
                    begin
                      LogAiToolResult(Format('%s: declined by user', [AIToolKindId(calls[i].Kind)]));
                      roundResultsLog := roundResultsLog + Format('  - %s: declined by user', [AIToolKindId(calls[i].Kind)]) + sLineBreak;
                      Continue;
                    end;
                  execOk := dispatcher.Execute(calls[i], resultText);
                  if execOk and (calls[i].Kind = atkAddSampleToTimeline) then
                    placedSampleEver := True;
                  LogAiToolResult(Format('%s: %s', [AIToolKindId(calls[i].Kind), resultText]));
                  roundResultsLog := roundResultsLog + Format('  - %s: %s', [AIToolKindId(calls[i].Kind), resultText]) + sLineBreak;
                end;
              finally
                dispatcher.Free;
                HideStatusProgress;
              end;
            end;
          end;
        end;

        { Phase 26: MCP tool calls are informational only (see the header
          comment on UDAW.AI.MCPBridge) - executed and logged, never turned
          into a DAW mutation by this bridge. }
        if FMcpBridge <> nil then
        begin
          mcpCalls := FMcpBridge.ParseMCPToolCalls(resp.Content);
          for i := 0 to High(mcpCalls) do
          begin
            FMcpBridge.Execute(mcpCalls[i], resultText);
            LogAiToolResult(Format('mcp %s.%s: %s',
              [mcpCalls[i].ServerName, mcpCalls[i].ToolName, resultText]));
          end;
        end;

        { Decide whether to auto-continue with another round. This is what was
          missing before: a cut-off reply, or a batch reply that only ran
          discovery calls (FindSample/GetProjectInfo/GetTracks/...) without
          ever getting to AddTrack/SetTempo/AddSampleToTimeline, used to just
          stop here with nothing further happening and no explanation. Feed
          the tool results actually seen this round back into the transcript
          as a user turn, so the model can reference real file paths/track ids
          instead of guessing, and ask it to keep going. }
        if round >= MAX_AI_ROUNDS then
        begin
          if truncated or ((Length(calls) > 0) and not hadMutatingCall) or
             (sawTrackOrSampleTool and not placedSampleEver) then
            memAiLog.Lines.Add(Format(
              '--- stopped after %d round(s) (limit reached) - the task may be incomplete ---',
              [round]));
        end
        else if truncated then
        begin
          msg.Role := arUser;
          msg.Content := Format(
            'Your previous reply was cut off (finish reason "%s") before it finished. ' +
            'Do not repeat tool calls you already made - continue the plan and emit the ' +
            'remaining tool calls needed to finish the arrangement.', [resp.FinishReason]);
          if roundResultsLog <> '' then
            msg.Content := msg.Content + sLineBreak + 'Tool results so far this turn:' + sLineBreak + roundResultsLog;
          FAiHistory := FAiHistory + [msg];
          memAiLog.Lines.Add(Format('--- reply cut off (finish reason "%s"), auto-continuing (round %d/%d) ---',
            [resp.FinishReason, round + 1, MAX_AI_ROUNDS]));
          keepGoing := True;
        end
        else if (Length(calls) > 0) and not hadMutatingCall then
        begin
          { The model made only read-only/discovery calls (GetProjectInfo,
            FindSample, etc.) this round and stopped there with a normal
            finish reason - this is the "stops mid-flight after one lookup"
            symptom. Feed it the results and ask it to actually act on them,
            whether that means finishing an arrangement or just answering the
            user's question, rather than silently ending the turn. }
          msg.Role := arUser;
          msg.Content :=
            'Those were read-only/discovery calls. Use their results below to now take the ' +
            'next step - emit any mutating tool calls needed (e.g. AddTrack, SetTempo, ' +
            'AddSampleToTimeline) to actually do the task, or give your final answer if the ' +
            'lookup was all that was needed.' +
            sLineBreak + 'Tool results:' + sLineBreak + roundResultsLog;
          FAiHistory := FAiHistory + [msg];
          memAiLog.Lines.Add(Format('--- only discovery tool calls so far, auto-continuing (round %d/%d) ---',
            [round + 1, MAX_AI_ROUNDS]));
          keepGoing := True;
        end
        else if sawTrackOrSampleTool and not placedSampleEver then
        begin
          { Tracks got created and/or FindSample was searched, but no
            AddSampleToTimeline call has landed yet in this whole turn - the
            "channels exist but carry no audio" symptom. Make the model
            commit: name the exact file it is choosing for each part and
            place it, instead of stopping after building empty structure. }
          msg.Role := arUser;
          msg.Content :=
            'No audio has actually been placed on the timeline yet - tracks/searches alone do ' +
            'not add sound. For each track, state which specific file (exact "path" from a ' +
            'FindSample result) you are choosing and why, then emit an AddSampleToTimeline call ' +
            'for it. Every track you created must end up with at least one clip.' +
            sLineBreak + 'Tool results:' + sLineBreak + roundResultsLog;
          FAiHistory := FAiHistory + [msg];
          memAiLog.Lines.Add(Format('--- tracks/samples searched but nothing placed yet, auto-continuing (round %d/%d) ---',
            [round + 1, MAX_AI_ROUNDS]));
          keepGoing := True;
        end;
      end;
    except
      on E: Exception do
        memAiLog.Lines.Add('ERROR: ' + E.Message);
    end;
  finally
    HideStatusProgress;
    Screen.Cursor := crDefault;
  end;
end;

procedure TfrmMain.btnAiSendClick(Sender: TObject);
var
  prompt: string;
begin
  prompt := Trim(edtAiPrompt.Text);
  if prompt = '' then Exit;
  edtAiPrompt.Text := '';
  SendAiChatPrompt(prompt);
end;

procedure TfrmMain.btnAiClearClick(Sender: TObject);
begin
  FAiHistory := nil;
  memAiLog.Lines.Add('--- chat cleared ---');
end;

{ "Generate Tune from Browser Library": makes the AI system aware of the
  Browser tab's own folders (via GetAiBrowserRoots -> the FindSample/
  AddSampleToTimeline tools already exposed to it, see UDAW.AI.ToolCommands)
  and asks it to plan and build a whole timeline arrangement in one go,
  instead of the user having to prompt it into doing that one tool call at a
  time. Any text already typed in the prompt box is folded in as a creative
  brief. Uses SendAiChatPrompt's batch-confirm mode so one summary dialog
  covers the whole arrangement rather than a confirmation per clip. }
procedure TfrmMain.GenerateTimelineTuneFromAI;
var
  pid, brief, prompt: string;
  roots: TArray<string>;
begin
  if not RequireRegistration('AI tune generation') then Exit;
  if (cboAiProvider.ItemIndex < 0) or (cboAiProvider.ItemIndex > High(AI_KNOWN_PROVIDERS)) then Exit;
  pid := AI_KNOWN_PROVIDERS[cboAiProvider.ItemIndex];
  if SameText(pid, 'suno') then
  begin
    memAiLog.Lines.Add('Generate Tune from Browser Library needs a chat provider (OpenAI/Claude/DeepSeek) - ' +
      'Suno generates a finished audio file directly via its own Generate button instead.');
    Exit;
  end;
  if FProject = nil then
  begin
    memAiLog.Lines.Add('Generate Tune from Browser Library: open or create a project first.');
    Exit;
  end;
  roots := GetAiBrowserRoots;
  if Length(roots) = 0 then
  begin
    memAiLog.Lines.Add('Generate Tune from Browser Library: add at least one folder to the Browser tab first.');
    Exit;
  end;

  brief := Trim(edtAiPrompt.Text);
  edtAiPrompt.Text := '';
  prompt :=
    'Compose a complete timeline-based tune using only audio files discoverable through the FindSample tool ' +
    '(it searches every folder registered in the Browser tab). ' +
    IfThen(brief <> '', 'Creative brief: ' + brief + '. ', '') +
    'Plan an arrangement with distinct tracks (for example drums, bass, melody, pads) and a coherent song ' +
    'structure (intro, main section(s), outro). Use FindSample to discover suitable files for each part, ' +
    'AddTrack to create each track before placing clips on it, SetTempo if the material calls for a specific ' +
    'tempo, and AddSampleToTimeline to place every clip on its track at the right position_sec. Briefly explain ' +
    'your plan in one or two sentences, then emit every tool call needed to build the whole arrangement in this ' +
    'single reply.';
  memAiLog.Lines.Add(Format('--- Generating a timeline tune from %d Browser folder(s) ---', [Length(roots)]));
  SendAiChatPrompt(prompt, True);
end;

procedure TfrmMain.btnAiGenerateTuneClick(Sender: TObject);
begin
  GenerateTimelineTuneFromAI;
end;

{ ---- Phase 27/28: AI Mixing / Mastering assistants. Both analyze the
  current timeline mix offline (UDAW.DSP.Analysis over a TTimelinePlayer
  render - the same non-destructive render path Play uses, just rendered to
  a buffer instead of the audio device) and drive a session object that
  performs its suggestions as real, undo-safe mixer commands: Preview hears
  it immediately, Compare A/Bs it against the untouched original, Apply
  keeps it, Reject undoes it. Nothing is ever changed without going through
  one of those explicit actions. ---- }

function TfrmMain.RenderMixAnalysis: TAudioAnalysisResult;
const
  ANALYZE_SECONDS = 20.0;
var
  player: TTimelinePlayer;
  res: TOfflineResult;
  sr: Integer;
begin
  Result := TAudioAnalysisResult.Empty;
  if FProject = nil then Exit;
  sr := 48000;
  player := TTimelinePlayer.Create(FProject.Timeline);
  try
    player.EnsureSourcesLoaded;
    res := RenderSourceOffline(player.AsSource, sr, 2, Round(ANALYZE_SECONDS * sr), 512);
    if (res.Channels < 2) or (res.Frames = 0) then Exit;
    Result := AnalyzeStereoBuffer(res.Planar[0], res.Planar[1], sr);
  finally
    player.Free;
  end;
end;

{ Shared by the Scope and Advanced DSP tabs' "Project Mix (Timeline)" signal
  choice: the same non-destructive TTimelinePlayer render RenderMixAnalysis
  above uses, so those tabs can finally analyze/process the user's actual
  project audio instead of only a synthetic tone/sweep/noise signal - see the
  header comment on RenderMixAnalysis. Empty (zero Frames) when there is no
  open project or the timeline currently has no audio. }
function TfrmMain.RenderProjectMixOffline(ASeconds: Double; ASampleRate: Integer): TOfflineResult;
var
  player: TTimelinePlayer;
begin
  Result.Channels := 0;
  Result.Frames := 0;
  if FProject = nil then Exit;
  player := TTimelinePlayer.Create(FProject.Timeline);
  try
    player.EnsureSourcesLoaded;
    Result := RenderSourceOffline(player.AsSource, ASampleRate, 2,
      Round(ASeconds * ASampleRate), 512);
  finally
    player.Free;
  end;
end;

procedure TfrmMain.EnsureMixSession;
begin
  if (FMixSession = nil) or (FAiSessionDoc <> FProject) then
  begin
    FreeAndNil(FMixSession);
    FMixSession := TAIMixingSession.Create(FProject, FCmds);
  end;
end;

procedure TfrmMain.EnsureMasterSession;
begin
  if (FMasterSession = nil) or (FAiSessionDoc <> FProject) then
  begin
    FreeAndNil(FMasterSession);
    FMasterSession := TAIMasteringSession.Create(FProject, FCmds);
  end;
end;

procedure TfrmMain.btnAiAnalyzeMixClick(Sender: TObject);
var
  analysis: TAudioAnalysisResult;
  i: Integer;
begin
  if not RequireRegistration('The AI mixing assistant') then Exit;
  if FProject = nil then Exit;
  FAiSessionDoc := FProject;
  EnsureMixSession;
  Screen.Cursor := crHourGlass;
  try
    analysis := RenderMixAnalysis;
  finally
    Screen.Cursor := crDefault;
  end;
  memAiLog.Lines.Add('--- Analyze Mix ---');
  memAiLog.Lines.Add(AnalysisResultToJSONString(analysis));
  FMixSession.Analyze(analysis);
  if Length(FMixSession.Suggestions) = 0 then
    memAiLog.Lines.Add('No suggestions - the mix looks healthy.')
  else
    for i := 0 to High(FMixSession.Suggestions) do
      memAiLog.Lines.Add('  ' + MixSuggestionToText(FMixSession.Suggestions[i]));
end;

procedure TfrmMain.btnAiMixPreviewClick(Sender: TObject);
begin
  if FMixSession = nil then Exit;
  FMixSession.Preview;
  memAiLog.Lines.Add('Mixing suggestions previewed (Compare/Apply/Reject to resolve).');
end;

procedure TfrmMain.btnAiMixCompareClick(Sender: TObject);
begin
  if FMixSession = nil then Exit;
  FMixSession.CompareToggle;
  memAiLog.Lines.Add('Mixing: toggled Original <-> AI Recommendation.');
end;

procedure TfrmMain.btnAiMixApplyClick(Sender: TObject);
begin
  if FMixSession = nil then Exit;
  FMixSession.Apply;
  memAiLog.Lines.Add('Mixing suggestions applied (kept on the undo stack).');
end;

procedure TfrmMain.btnAiMixRejectClick(Sender: TObject);
begin
  if FMixSession = nil then Exit;
  FMixSession.Reject;
  memAiLog.Lines.Add('Mixing suggestions rejected (reverted).');
end;

procedure TfrmMain.btnAiSuggestMasteringClick(Sender: TObject);
var
  analysis: TAudioAnalysisResult;
begin
  if not RequireRegistration('The AI mastering assistant') then Exit;
  if FProject = nil then Exit;
  FAiSessionDoc := FProject;
  EnsureMasterSession;
  Screen.Cursor := crHourGlass;
  try
    analysis := RenderMixAnalysis;
  finally
    Screen.Cursor := crDefault;
  end;
  memAiLog.Lines.Add('--- Suggest Mastering ---');
  memAiLog.Lines.Add(AnalysisResultToJSONString(analysis));
  FMasterSession.Analyze(analysis);
  memAiLog.Lines.Add(MasteringSuggestionToText(FMasterSession.Suggestion));
end;

procedure TfrmMain.btnAiMasterPreviewClick(Sender: TObject);
begin
  if FMasterSession = nil then Exit;
  FMasterSession.Preview;
  memAiLog.Lines.Add('Mastering chain previewed on the master strip (Compare/Apply/Reject to resolve).');
end;

procedure TfrmMain.btnAiMasterCompareClick(Sender: TObject);
begin
  if FMasterSession = nil then Exit;
  FMasterSession.CompareToggle;
  memAiLog.Lines.Add('Mastering: toggled Original <-> AI Recommendation.');
end;

procedure TfrmMain.btnAiMasterApplyClick(Sender: TObject);
begin
  if FMasterSession = nil then Exit;
  FMasterSession.Apply;
  memAiLog.Lines.Add('Mastering chain applied (kept on the undo stack).');
end;

procedure TfrmMain.btnAiMasterRejectClick(Sender: TObject);
begin
  if FMasterSession = nil then Exit;
  FMasterSession.Reject;
  memAiLog.Lines.Add('Mastering chain rejected (reverted).');
end;

{ ---- Suno (Phase 24): generation-workflow + timeline ingestion over
       UDAW.AI.Suno. Submits a prompt to the configured proxy (App.Config
       section 'ai', key 'suno_base_url'; UDAW.AI.Suno.SUNO_DEFAULT_BASE_URL
       if unset), polls until the take(s) are ready, downloads the MP3,
       decodes it with the Phase 15 MP3 decoder, and drops it on the
       timeline as a new WAV-backed source + clip - the exact same
       AddSource/TAddTimelineClipCommand pattern btnTlAddClipClick uses for
       a file picked from disk. ---- }

function TfrmMain.CurrentSunoBaseUrl: string;
const
  CFG_SEC_AI = 'ai';
  CFG_AI_SUNO_BASE_URL = 'suno_base_url';
begin
  Result := Trim(edtSunoBaseUrl.Text);
  if Result = '' then
    if cboSunoApi.ItemIndex = 1 then Result := SUNO_MANAGED_BASE_URL
    else Result := SUNO_DEFAULT_BASE_URL;
  if (App <> nil) and (App.Config <> nil) then
  begin
    App.Config.SetString(CFG_SEC_AI, CFG_AI_SUNO_BASE_URL, Result);
    App.Config.SetInt('ai', 'suno_api_kind', cboSunoApi.ItemIndex);
    App.Config.SetString('ai', 'suno_model', CurrentSunoModel);
    App.Config.SetString('ai', 'suno_callback_url', Trim(edtSunoCallback.Text));
    App.Config.SetBool('ai', 'suno_advanced', chkSunoAdvanced.Checked);
    App.Config.Save;
  end;
end;

const
  { Real, documented SunoAPI.org / apibox.erweima.ai model enum (checked
    2026-09-18 against https://docs.sunoapi.org/suno-api/generate-music):
    V6/V6_WILD/V6_MINI are the current tier, V6 is the provider's own
    default; everything after it is listed there only as deprecated,
    kept for accounts still pinned to an older tier. cboSunoModel.Items
    (see the .dfm) must list these in the same order, one display string
    per id, with '(deprecated)' appended for the ids at index >= 3. }
  SUNO_MODEL_IDS: array[0..8] of string = (
    'V6', 'V6_WILD', 'V6_MINI', 'V5_5', 'V5', 'V4_5PLUS', 'V4_5ALL', 'V4_5', 'V4');

function TfrmMain.CurrentSunoModel: string;
begin
  if (cboSunoModel.ItemIndex >= 0) and (cboSunoModel.ItemIndex <= High(SUNO_MODEL_IDS)) then
    Result := SUNO_MODEL_IDS[cboSunoModel.ItemIndex]
  else
    Result := SUNO_MANAGED_DEFAULT_MODEL;
end;

procedure TfrmMain.SetSunoModel(const AModelId: string);
var
  i: Integer;
begin
  for i := 0 to High(SUNO_MODEL_IDS) do
    if SameText(SUNO_MODEL_IDS[i], Trim(AModelId)) then
    begin
      cboSunoModel.ItemIndex := i;
      Exit;
    end;
  cboSunoModel.ItemIndex := 0; // unknown/blank id - fall back to the provider's own default (V6)
end;

{ Default UX: Suno is configured automatically (managed SunoAPI.org, its base
  URL, default model and a placeholder callback UDAW never actually needs to
  receive - see SUNO_MANAGED_PLACEHOLDER_CALLBACK), so the user only has to
  paste in their own API key on the Provider row. chkSunoAdvanced unlocks the
  API type/base URL/model/callback fields for a self-hosted gcui-art/suno-api
  proxy or a non-default managed account. }
procedure TfrmMain.ApplySunoAutoConfig;
begin
  cboSunoApi.ItemIndex := 1;
  cboSunoApiChange(nil);
  if Trim(edtSunoCallback.Text) = '' then edtSunoCallback.Text := SUNO_MANAGED_PLACEHOLDER_CALLBACK;
  cboSunoApi.Enabled := False;
  edtSunoBaseUrl.Enabled := False;
  cboSunoModel.Enabled := False;
  edtSunoCallback.Enabled := False;
end;

procedure TfrmMain.chkSunoAdvancedClick(Sender: TObject);
begin
  if chkSunoAdvanced.Checked then
  begin
    cboSunoApi.Enabled := True;
    edtSunoBaseUrl.Enabled := True;
    cboSunoApiChange(nil); // restores Model/Callback Enabled per the current API type
  end
  else
    ApplySunoAutoConfig;
  if (App <> nil) and (App.Config <> nil) then
  begin
    App.Config.SetBool('ai', 'suno_advanced', chkSunoAdvanced.Checked);
    App.Config.Save;
  end;
end;

procedure TfrmMain.btnSunoTestClick(Sender: TObject);
var
  key, msg: string;
  client: TSunoClient;
  ok: Boolean;
begin
  if not RequireRegistration('Testing the Suno connection') then Exit;
  key := '';
  GetAIApiKey('suno', key);
  Screen.Cursor := crHourGlass;
  try
    client := TSunoClient.Create(key, CurrentSunoBaseUrl, TSunoApiKind(cboSunoApi.ItemIndex));
    try
      ok := client.CheckConnection(msg);
    finally
      client.Free;
    end;
  finally
    Screen.Cursor := crDefault;
  end;
  memAiLog.Lines.Add('Suno test: ' + msg);
  if not ok then
    memAiLog.Lines.Add('Suno: check the proxy URL above (a suno-api proxy must actually be running there) and that the stored key matches what that proxy expects.');
end;

procedure TfrmMain.btnSunoGenerateClick(Sender: TObject);
var
  key: string;
  req: TSunoGenerationRequest;
  kind: TSunoApiKind;
begin
  if not RequireRegistration('AI music generation (Suno)') then Exit;
  if (FProject = nil) or (FSunoJob <> nil) then Exit;
  if chkSunoCustom.Checked and (Length(memSunoLyrics.Text) > SUNO_LYRICS_MAX_CHARS) then
  begin
    memAiLog.Lines.Add(Format('Suno: lyrics exceed the %d character limit (currently %d). Trim before generating.',
      [SUNO_LYRICS_MAX_CHARS, Length(memSunoLyrics.Text)]));
    Exit;
  end;
  key := '';
  GetAIApiKey('suno', key);
  kind := TSunoApiKind(cboSunoApi.ItemIndex);
  req := Default(TSunoGenerationRequest);
  if chkSunoCustom.Checked then
    req.Prompt := Trim(memSunoLyrics.Text)
  else
    req.Prompt := Trim(edtSunoPrompt.Text);
  req.Tags := Trim(StringReplace(StringReplace(edtSunoStyle.Text, #13#10, ' ', [rfReplaceAll]), #13, ' ', [rfReplaceAll]));
  req.Title := Trim(edtSunoTitle.Text);
  req.Instrumental := chkSunoInstrumental.Checked;
  req.CustomMode := chkSunoCustom.Checked;
  req.Model := CurrentSunoModel;
  req.CallbackURL := Trim(edtSunoCallback.Text);
  req.RefMode := TSunoReferenceMode(cboSunoRefMode.ItemIndex);
  if req.RefMode <> srmNone then
  begin
    req.RefLocalPath := SelectedSunoRefPath;
    if req.RefLocalPath = '' then
    begin
      memAiLog.Lines.Add('Suno: select a recording on the Recordings tab to Cover/Extend, or set Reference audio back to None.');
      Exit;
    end;
    req.RefContinueAt := Max(0, StrToFloatDef(Trim(edtSunoContinueAt.Text), 0));
  end;
  try
    FSunoJob := TSunoGenerationJob.Create(key, CurrentSunoBaseUrl, kind, req, RecordingRootPath);
    FSunoTrackId := TlSelectedAudioTrackId;
    FSunoPosition := FTlView.Snap(FProject.Timeline.PlayheadSeconds);
    FTrackedJobs.Add(FSunoJob);
    App.Jobs.Submit(FSunoJob, False);
    memAiLog.Lines.Add('Suno: generation queued. Progress is in the status bar and Jobs tab. Cancel stops local work; the provider may still charge.');
  except
    on E: Exception do
    begin
      if FSunoJob <> nil then
      begin
        FTrackedJobs.Remove(FSunoJob);
        FreeAndNil(FSunoJob);
      end;
      memAiLog.Lines.Add('Suno: ' + E.Message);
    end;
  end;
end;

procedure TfrmMain.btnSunoCancelClick(Sender: TObject);
begin
  if FSunoJob <> nil then FSunoJob.Cancel;
end;

procedure TfrmMain.cboSunoApiChange(Sender: TObject);
begin
  if cboSunoApi.ItemIndex = 1 then edtSunoBaseUrl.Text := SUNO_MANAGED_BASE_URL
  else edtSunoBaseUrl.Text := SUNO_DEFAULT_BASE_URL;
  cboSunoModel.Enabled := (cboSunoApi.ItemIndex = 1) and chkSunoAdvanced.Checked;
  edtSunoCallback.Enabled := (cboSunoApi.ItemIndex = 1) and chkSunoAdvanced.Checked;
end;

{ Custom mode swaps the single-line "description" prompt for a full-song
  lyrics memo (plus its required Style/Title fields) - the two inputs mean
  different things to Suno, so only the one that applies is ever shown. }
procedure TfrmMain.chkSunoCustomClick(Sender: TObject);
begin
  edtSunoPrompt.Visible := not chkSunoCustom.Checked;
  memSunoLyrics.Visible := chkSunoCustom.Checked;
  lblSunoLyricsCount.Visible := chkSunoCustom.Checked;
  lblSunoStyle.Visible := chkSunoCustom.Checked;
  edtSunoStyle.Visible := chkSunoCustom.Checked;
  lblSunoTitle.Visible := chkSunoCustom.Checked;
  edtSunoTitle.Visible := chkSunoCustom.Checked;
  if chkSunoCustom.Checked then
    lblSunoPrompt.Caption := 'Lyrics'
  else
    lblSunoPrompt.Caption := 'Suno prompt';
  memSunoLyricsChange(nil);
end;

{ Lyrics box right-click: Clear empties it; Save as .txt writes the lyrics to a
  plain UTF-8 text file so they can be kept safely outside the project. }
procedure TfrmMain.pmSunoLyricsPopup(Sender: TObject);
var
  hasText: Boolean;
begin
  hasText := memSunoLyrics.Text <> '';
  pmSunoLyricsClear.Enabled := hasText;
  pmSunoLyricsSave.Enabled := hasText;
end;

procedure TfrmMain.pmSunoLyricsClearClick(Sender: TObject);
begin
  if memSunoLyrics.Text = '' then Exit;
  if MessageDlg('Clear all lyrics? This cannot be undone.' + sLineBreak +
    'Use "Save as .txt..." first if you want to keep a copy.',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  memSunoLyrics.Clear;
  memSunoLyricsChange(nil);
end;

procedure TfrmMain.pmSunoLyricsSaveClick(Sender: TObject);
var
  sl: TStringList;
begin
  if memSunoLyrics.Text = '' then Exit;
  if edDirExport.Text <> '' then dlgSaveLyrics.InitialDir := edDirExport.Text;
  if not dlgSaveLyrics.Execute then Exit;
  sl := TStringList.Create;
  try
    try
      sl.Text := memSunoLyrics.Text;
      sl.SaveToFile(dlgSaveLyrics.FileName, TEncoding.UTF8);
      Logger.Info('ui', 'Lyrics saved: ' + dlgSaveLyrics.FileName);
    except
      on E: Exception do
        MessageDlg('Could not save lyrics: ' + E.Message, mtError, [mbOK], 0);
    end;
  finally
    sl.Free;
  end;
end;

procedure TfrmMain.memSunoLyricsChange(Sender: TObject);
var
  len: Integer;
begin
  len := Length(memSunoLyrics.Text);
  { SunoAPI.org custom-mode lyrics are capped at 5000 characters; UDAW enforces
    it client-side too so users see the limit before a paid submission fails. }
  if len > SUNO_LYRICS_MAX_CHARS then
  begin
    memSunoLyrics.SelStart := SUNO_LYRICS_MAX_CHARS;
    memSunoLyrics.SelLength := len - SUNO_LYRICS_MAX_CHARS;
    memSunoLyrics.SelText := '';
    len := SUNO_LYRICS_MAX_CHARS;
  end;
  lblSunoLyricsCount.Caption := Format('%d / %d characters', [len, SUNO_LYRICS_MAX_CHARS]);
end;

procedure TfrmMain.cboSunoRefModeChange(Sender: TObject);
begin
  lblSunoContinueAt.Visible := cboSunoRefMode.ItemIndex = Ord(srmExtend);
  edtSunoContinueAt.Visible := cboSunoRefMode.ItemIndex = Ord(srmExtend);
end;

{ Reference recordings persist across sessions as a '|'-joined list of local
  paths (App.Config has no native list type) under [ai]/suno_refs. Missing
  files (moved/deleted outside UDAW) are silently dropped on load rather than
  shown as broken entries. }
procedure TfrmMain.LoadSunoRefs;
var
  raw: string;
  parts: TArray<string>;
  i: Integer;
begin
  FSunoRefs.Clear;
  if (App <> nil) and (App.Config <> nil) then
  begin
    raw := App.Config.GetString('ai', 'suno_refs', '');
    if raw <> '' then
    begin
      parts := raw.Split(['|']);
      for i := 0 to High(parts) do
        if FileExists(parts[i]) then FSunoRefs.Add(parts[i]);
    end;
  end;
  lstSunoRefs.Items.Clear;
  for i := 0 to FSunoRefs.Count - 1 do
    lstSunoRefs.Items.Add(ExtractFileName(FSunoRefs[i]));
end;

procedure TfrmMain.SaveSunoRefs;
var
  raw: string;
  i: Integer;
begin
  if (App = nil) or (App.Config = nil) then Exit;
  raw := '';
  for i := 0 to FSunoRefs.Count - 1 do
  begin
    if i > 0 then raw := raw + '|';
    raw := raw + FSunoRefs[i];
  end;
  App.Config.SetString('ai', 'suno_refs', raw);
  App.Config.Save;
end;

function TfrmMain.SelectedSunoRefPath: string;
begin
  Result := '';
  if (lstSunoRefs.ItemIndex >= 0) and (lstSunoRefs.ItemIndex < FSunoRefs.Count) then
    Result := FSunoRefs[lstSunoRefs.ItemIndex];
end;

procedure TfrmMain.btnSunoRefAddClick(Sender: TObject);
begin
  if not dlgSunoRefOpen.Execute then Exit;
  if FSunoRefs.IndexOf(dlgSunoRefOpen.FileName) >= 0 then Exit;
  FSunoRefs.Add(dlgSunoRefOpen.FileName);
  lstSunoRefs.Items.Add(ExtractFileName(dlgSunoRefOpen.FileName));
  lstSunoRefs.ItemIndex := lstSunoRefs.Items.Count - 1;
  SaveSunoRefs;
end;

procedure TfrmMain.btnSunoRefRemoveClick(Sender: TObject);
var
  idx: Integer;
begin
  idx := lstSunoRefs.ItemIndex;
  if (idx < 0) or (idx >= FSunoRefs.Count) then Exit;
  FSunoRefs.Delete(idx);
  lstSunoRefs.Items.Delete(idx);
  SaveSunoRefs;
end;

{ Rescans the Recordings folder and adds any audio file not already listed -
  never removes an existing entry, so manually Added files outside that
  folder (or ones later moved away) are left for the user to Remove. }
procedure TfrmMain.btnSunoRefRefreshClick(Sender: TObject);
var
  sr: TSearchRec;
  dir, ext: string;
  added: Integer;
begin
  dir := IncludeTrailingPathDelimiter(RecordingRootPath);
  added := 0;
  if FindFirst(dir + '*.*', faAnyFile, sr) = 0 then
  begin
    try
      repeat
        if (sr.Attr and faDirectory) <> 0 then Continue;
        ext := LowerCase(ExtractFileExt(sr.Name));
        if (ext <> '.wav') and (ext <> '.mp3') and (ext <> '.flac') then Continue;
        if FSunoRefs.IndexOf(dir + sr.Name) >= 0 then Continue;
        FSunoRefs.Add(dir + sr.Name);
        lstSunoRefs.Items.Add(sr.Name);
        Inc(added);
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
  end;
  SaveSunoRefs;
  memAiLog.Lines.Add(Format('Suno recordings: added %d file(s) from %s.', [added, dir]));
end;

{ Toggles a native-quality (no downmix/resample - see UDAW.Voice.Capture's
  TLiveCapture) Start/Stop recording of the current input device straight
  into the Recordings folder, then adds the result to the reference list.
  Draining happens on tmrUITimer's tick (DrainSunoRefRecording), same as
  every other polled UI refresh - no dedicated thread or timer needed. }
procedure TfrmMain.btnSunoRefRecordClick(Sender: TObject);
begin
  if FSunoRefCapture <> nil then
  begin
    DrainSunoRefRecording;
    if FSunoRefCapture.SaveAndStop(FSunoRefCapturePath) then
    begin
      FSunoRefs.Add(FSunoRefCapturePath);
      lstSunoRefs.Items.Add(ExtractFileName(FSunoRefCapturePath));
      SaveSunoRefs;
      memAiLog.Lines.Add('Suno: recorded ' + ExtractFileName(FSunoRefCapturePath));
    end
    else
      memAiLog.Lines.Add('Suno: recording captured no audio - no input device open?');
    FreeAndNil(FSunoRefCapture);
    btnSunoRefRecord.Caption := 'Record';
    Exit;
  end;

  if (App = nil) or (App.Audio = nil) or (App.Audio.Granted.CaptureChannels <= 0) then
  begin
    memAiLog.Lines.Add('Suno: no capture-capable input device is open.');
    Exit;
  end;
  ForceDirectories(RecordingRootPath);
  FSunoRefCapturePath := IncludeTrailingPathDelimiter(RecordingRootPath) +
    'suno_ref_' + FormatDateTime('yyyymmdd_hhnnss', Now) + '.wav';
  FSunoRefCapture := TLiveCapture.Create(App.Audio);
  btnSunoRefRecord.Caption := 'Stop (0:00)';
end;

procedure TfrmMain.DrainSunoRefRecording;
var
  secs: Integer;
begin
  if FSunoRefCapture = nil then Exit;
  FSunoRefCapture.Poll;
  secs := Trunc(FSunoRefCapture.DurationSeconds);
  btnSunoRefRecord.Caption := Format('Stop (%d:%.2d)', [secs div 60, secs mod 60]);
end;

{ Generated Suno takes are real paid output kept as named .wav files in the
  user's Recordings folder (see RecordingRootPath and UDAW.AI.Suno's
  UniqueSunoWavPath) - not Cache, which the OS or a cleanup tool may
  legitimately purge. This just gets the user into that folder. Creates it
  on demand so the menu item works even before a first Generate. }
procedure TfrmMain.mnuAiOpenCacheClick(Sender: TObject);
var
  dir: string;
begin
  dir := IncludeTrailingPathDelimiter(RecordingRootPath);
  ForceDirectories(dir);
  OpenInShell(dir);
end;

procedure TfrmMain.FinishSunoJob;
var
  job: TSunoGenerationJob;
  asset: TSunoAsset;
  src: TMediaSource;
  cmd: TAddTimelineClipCommand;
  trackId: Integer;
begin
  if (FSunoJob = nil) or not FSunoJob.IsTerminal then Exit;
  job := FSunoJob;
  FSunoJob := nil; // consume once; tracked jobs keep ownership until shutdown
  if job.Status <> jsSucceeded then
  begin
    memAiLog.Lines.Add('Suno: ' + JobStatusName(job.Status) + ' ' + job.ErrorMessage);
    Exit;
  end;
  try
    for asset in job.Assets do
    begin
      trackId := FSunoTrackId;
      if FProject.Timeline.TrackById(trackId) = nil then trackId := -1;
      if trackId < 0 then trackId := TlNewAudioTrackId;
      src := FProject.Timeline.AddSource(asset.Path, asset.SampleRate, asset.Channels, asset.Frames);
      cmd := TAddTimelineClipCommand.Create(FProject, trackId, src.Id,
        IfThen(asset.Title <> '', asset.Title, 'Suno take'),
        FSunoPosition, 0, asset.Frames / asset.SampleRate);
      FCmds.Perform(cmd);
      FTlSelClipId := cmd.CreatedId;
      ApplyBaselineTempoOnImport(cmd.CreatedId);
      memAiLog.Lines.Add('Suno: imported ' + asset.Path);
      FSunoTrackId := -1; // alternative takes get separate lanes, same start
    end;
    RefreshTimelineTab;
  except
    on E: Exception do memAiLog.Lines.Add('Suno import failed: ' + E.Message + '. Downloaded WAVs remain in the Suno cache.');
  end;
end;

{ ---- Voice commands (Phase 25): capture -> transcribe -> act/chat.
       UDAW.Voice.Capture drains a few seconds of the engine's live input
       to a WAV file; UDAW.Voice.Recognition transcribes it (Windows/
       System.Speech); UDAW.Voice.Command matches the transcript against a
       small fixed transport/edit vocabulary and, on a miss, the text is
       just sent to the AI chat like any typed prompt. ---- }

procedure TfrmMain.btnVoiceRecordClick(Sender: TObject);
begin
  if FRecWriter <> nil then
  begin
    MessageDlg('Stop live recording before changing the project or audio input.', mtInformation, [mbOK], 0);
    Exit;
  end;
  RunVoicePipeline;
end;

procedure TfrmMain.RunVoicePipeline;
var
  wavPath, text: string;
  action: TVoiceAction;
begin
  if (App = nil) or (App.Audio = nil) then
  begin
    memAiLog.Lines.Add('Voice: audio engine not available.');
    Exit;
  end;
  if App.Audio.Granted.CaptureChannels <= 0 then
  begin
    memAiLog.Lines.Add('Voice: no capture-capable input device is open.');
    Exit;
  end;
  if not VoiceRecognitionAvailable then
  begin
    memAiLog.Lines.Add('Voice: speech recognition is not available on this platform yet.');
    Exit;
  end;

  wavPath := Paths.Temp + 'voice_command.wav';
  memAiLog.Lines.Add('Voice: listening...');
  Application.ProcessMessages;

  Screen.Cursor := crHourGlass;
  try
    try
      if not CaptureVoiceToWavFile(App.Audio, wavPath, 4.0) then
      begin
        memAiLog.Lines.Add('Voice: no input captured.');
        Exit;
      end;
    except
      on E: Exception do
      begin
        memAiLog.Lines.Add('Voice: capture FAILED - ' + E.Message);
        Exit;
      end;
    end;

    if not TranscribeWavFile(wavPath, text) then
    begin
      memAiLog.Lines.Add('Voice: ' + text);
      Exit;
    end;

    memAiLog.Lines.Add('Voice heard: "' + text + '"');

    action := ParseVoiceCommand(text);
    case action of
      vaNone: SendAiChatPrompt(text);
      vaPlay: btnAudioStartClick(Self);
      vaStop: btnAudioStopClick(Self);
      vaRecord: btnRecArmClick(Self);
      vaUndo: btnUndoClick(Self);
      vaRedo: btnRedoClick(Self);
      vaSaveProject: btnProjectSaveClick(Self);
      vaNewAudioTrack: btnTlAddTrackClick(Self);
      vaClearChat: btnAiClearClick(Self);
    end;
    if action <> vaNone then
      memAiLog.Lines.Add('Voice: executed "' + VoiceActionName(action) + '".');
  finally
    Screen.Cursor := crDefault;
  end;
end;

procedure TfrmMain.RefreshAudio;
var
  eng: TAudioEngine;
  pk: Single;
begin
  if (App = nil) or (App.Audio = nil) then
  begin
    memAudio.Lines.Text := '(audio engine not created)';
    Exit;
  end;
  eng := App.Audio;
  lblAudioState.Caption := 'state: ' + AudioEngineStateName(eng.State);
  { Describe() carries live per-callback counters (frame count, CPU load),
    so this text changes on essentially every tmrUI tick while the engine is
    running - reassigning TStrings.Text outright repaints the whole memo
    every time, which flickered visibly during live monitoring.
    BeginUpdate/EndUpdate wraps that in a single WM_SETREDRAW-suppressed
    update (both VCL's TMemoStrings and LCL's TMemo.Lines implement it that
    way), so the memo only actually repaints once, after the new text is
    already in place. }
  memAudio.Lines.BeginUpdate;
  try
    memAudio.Lines.Text := eng.Describe;
  finally
    memAudio.Lines.EndUpdate;
  end;

  pk := eng.OutputPeak(0);
  if pk > 1 then pk := 1;
  pbOutL.Position := Round(pk * 1000);
  if eng.OutputChannels > 1 then pk := eng.OutputPeak(1) else pk := eng.OutputPeak(0);
  if pk > 1 then pk := 1;
  pbOutR.Position := Round(pk * 1000);

  mnuAudioStart.Enabled := eng.State in [aesOpen, aesIdle, aesFailed, aesLost];
  pmAudioStart.Enabled := mnuAudioStart.Enabled;
  mnuAudioStop.Enabled := eng.State = aesRunning;
  pmAudioStop.Enabled := mnuAudioStop.Enabled;
  if FTonePlaying then
  begin
    mnuAudioTone.Caption := 'Stop test tone';
    pmAudioTone.Caption := 'Stop test tone';
  end
  else
  begin
    mnuAudioTone.Caption := 'Test tone 440 Hz';
    pmAudioTone.Caption := 'Test tone 440 Hz';
  end;
end;

procedure TfrmMain.btnAudioStartClick(Sender: TObject);
begin
  if (App = nil) or (App.Audio = nil) then Exit;
  if App.Audio.State in [aesIdle, aesFailed] then
    App.Audio.Open(True)
  else
    App.Audio.Start;
  RefreshAudio;
end;

procedure TfrmMain.btnAudioStopClick(Sender: TObject);
begin
  if FRecWriter <> nil then
  begin
    MessageDlg('Stop live recording before changing the project or audio input.', mtInformation, [mbOK], 0);
    Exit;
  end;
  if (App <> nil) and (App.Audio <> nil) then
  begin
    App.Audio.Stop;
    RefreshAudio;
  end;
end;

procedure TfrmMain.btnAudioToneClick(Sender: TObject);
begin
  if (App = nil) or (App.Audio = nil) then Exit;
  FTonePlaying := not FTonePlaying;
  if FTonePlaying then
    App.Audio.SetSource(TToneSource.Create(osSine, 440.0, 0.25))
  else
    App.Audio.ClearSource;
  Logger.Info('ui', 'audio test tone ' + BoolToStr(FTonePlaying, True));
  RefreshAudio;
end;

procedure TfrmMain.btnAudioResetClick(Sender: TObject);
begin
  if FRecWriter <> nil then StopLiveRecording;
  if (App <> nil) and (App.Audio <> nil) then
  begin
    App.Audio.NotifyDeviceLost('user requested device reset');
    RefreshAudio;
  end;
end;

procedure TfrmMain.btnAudioReopenClick(Sender: TObject);
begin
  if FRecWriter <> nil then
  begin
    MessageDlg('Stop live recording before changing the project or audio input.', mtInformation, [mbOK], 0);
    Exit;
  end;
  if (App <> nil) and (App.Audio <> nil) then
  begin
    App.Audio.Reopen;
    RefreshAudio;
  end;
end;

procedure TfrmMain.btnDspAnalyzeClick(Sender: TObject);
begin
  RunDspAnalysis;
end;

procedure TfrmMain.chkDspLiveClick(Sender: TObject);
begin
  if chkDspLive.Checked then
    RunDspAnalysis;
end;

procedure TfrmMain.pbSpectrumPaint(Sender: TObject);
var
  c: TCanvas;
  w, h, i, n, x, y, k: Integer;
  topDb, botDb, hz, fmin, fmax: Double;

  function XForHz(AHz: Double): Integer;
  begin
    if AHz < fmin then AHz := fmin;
    Result := Round((Ln(AHz) - Ln(fmin)) / (Ln(fmax) - Ln(fmin)) * (w - 1));
  end;

  function YForDb(ADb: Double): Integer;
  begin
    if ADb > topDb then ADb := topDb;
    if ADb < botDb then ADb := botDb;
    Result := Round((topDb - ADb) / (topDb - botDb) * (h - 1));
  end;

begin
  w := pbSpectrum.Width;
  h := pbSpectrum.Height;
  if (w <= 0) or (h <= 0) then Exit;
  { paint into an off-screen bitmap and blit it in one shot - pbSpectrum is
    invalidated at near-frame rate while "Live" is checked (RunDspAnalysis
    via tmrUITimer), and drawing the grid/curve straight to the on-screen DC
    flickered badly; mirrors pbMixerPaint/FMixBuffer. }
  FDspBuffer.SetSize(w, h);
  c := FDspBuffer.Canvas;
  c.Brush.Color := CurrentTheme.Background;
  c.FillRect(Rect(0, 0, w, h));

  topDb := 6;
  botDb := -114;
  fmin := 20;
  if FDspNyquist > fmin then fmax := FDspNyquist else fmax := 24000;

  { grid }
  c.Pen.Color := CurrentTheme.Grid;
  c.Font.Color := CurrentTheme.SecondaryText;
  for i := 0 to 6 do
  begin
    y := Round(i / 6 * (h - 1));
    c.MoveTo(0, y); c.LineTo(w, y);
    c.TextOut(2, y + 1, Format('%.0f dB', [topDb - i / 6 * (topDb - botDb)]));
  end;
  for k := 1 to 9 do
  begin
    x := XForHz(k * 100); c.MoveTo(x, 0); c.LineTo(x, h);
  end;
  for k := 1 to 24 do
  begin
    hz := k * 1000;
    if hz >= fmax then Break;
    x := XForHz(hz); c.MoveTo(x, 0); c.LineTo(x, h);
    c.TextOut(x + 2, h - 14, Format('%dk', [k]));
  end;

  n := Length(FDspDb);
  if n < 2 then
  begin
    c.Font.Color := CurrentTheme.MeterClip;
    c.TextOut(8, 8, 'no spectrum yet - press Analyze');
    pbSpectrum.Canvas.Draw(0, 0, FDspBuffer);
    Exit;
  end;

  c.Pen.Color := CurrentTheme.Waveform;
  for i := 1 to n - 1 do
  begin
    hz := i / (n - 1) * FDspNyquist;
    x := XForHz(hz);
    y := YForDb(FDspDb[i]);
    if i = 1 then c.MoveTo(x, y) else c.LineTo(x, y);
  end;
  pbSpectrum.Canvas.Draw(0, 0, FDspBuffer);
end;

{ ---- Audio graph demo (Phase 4): build a real node graph, compile it, and
       either analyse it with a deterministic offline render or route it live
       to the device engine. Every control is design-time. ---- }

procedure TfrmMain.BuildGraphPreset;
var
  g: TAudioGraph;
  sr, block: Integer;
  s1, s2, n1, n2, o: TAudioNode;
  ok: Boolean;
begin
  if (App <> nil) and (App.Audio <> nil) and (App.Audio.Granted.SampleRate > 0) then
  begin
    sr := App.Audio.Granted.SampleRate;
    block := App.Audio.Granted.BufferFrames;
  end
  else
  begin
    sr := 48000;
    block := 512;
  end;
  if block <= 0 then block := 512;

  g := TAudioGraph.Create(2);
  try
    case cboGraphPreset.ItemIndex of
      0:
        begin
          s1 := g.AddNode(nkSource, 'Osc');
          TGraphSourceNode(s1).SetTone(osSine, 440, 0.5);
          n1 := g.AddNode(nkGain, 'Trim');
          TGainNode(n1).GainDb := -6;
          o := g.AddNode(nkOutput, 'Master');
          g.Connect(s1.Id, n1.Id);
          g.Connect(n1.Id, o.Id);
        end;
      2:
        begin
          s1 := g.AddNode(nkSource, 'Osc A');
          TGraphSourceNode(s1).SetTone(osSine, 220, 0.3);
          s2 := g.AddNode(nkSource, 'Osc B');
          TGraphSourceNode(s2).SetTone(osSine, 660, 0.3);
          n1 := g.AddNode(nkBus, 'Sub bus');
          n2 := g.AddNode(nkGain, 'Trim');
          TGainNode(n2).GainDb := -3;
          o := g.AddNode(nkOutput, 'Master');
          g.Connect(s1.Id, n1.Id);
          g.Connect(s2.Id, n1.Id);
          g.Connect(n1.Id, n2.Id);
          g.Connect(n2.Id, o.Id);
        end;
      3:
        begin
          s1 := g.AddNode(nkSource, 'Osc');
          TGraphSourceNode(s1).SetTone(osSine, 1000, 0.4);
          n1 := g.AddNode(nkDelay, 'Delay');
          TDelayNode(n1).TimeMs := 250;
          TDelayNode(n1).Feedback := 0.35;
          TDelayNode(n1).Mix := 0.35;
          o := g.AddNode(nkOutput, 'Master');
          g.Connect(s1.Id, n1.Id);
          g.Connect(n1.Id, o.Id);
        end;
      4:
        begin
          s1 := g.AddNode(nkSource, 'Noise');
          TGraphSourceNode(s1).SetTone(osPinkNoise, 0, 0.5);
          n1 := g.AddNode(nkFilterChain, 'HP 300');
          TFilterChainNode(n1).DeserializeParams('mode=hp;freq=300;pairs=2');
          n2 := g.AddNode(nkPan, 'Pan');
          TPanNode(n2).Pos := -0.7;
          s2 := g.AddNode(nkMeter, 'Tap');
          o := g.AddNode(nkOutput, 'Master');
          g.Connect(s1.Id, n1.Id);
          g.Connect(n1.Id, n2.Id);
          g.Connect(n2.Id, s2.Id);
          g.Connect(s2.Id, o.Id);
        end;
    else
      begin
        s1 := g.AddNode(nkSource, 'Osc');
        TGraphSourceNode(s1).SetTone(osSaw, 220, 0.4);
        n1 := g.AddNode(nkBiquad, 'LP 1.2k');
        TBiquadNode(n1).SetFilter(bqLowpass, 1200, 0.70710678, 0);
        n2 := g.AddNode(nkMeter, 'Tap');
        o := g.AddNode(nkOutput, 'Master');
        g.Connect(s1.Id, n1.Id);
        g.Connect(n1.Id, n2.Id);
        g.Connect(n2.Id, o.Id);
      end;
    end;

    g.Prepare(sr, block, 2);
    ok := g.Compile;
    if not ok then
    begin
      memGraph.Lines.Text := 'graph did not compile:' + sLineBreak + g.LastError;
      g.Free;
      Exit;
    end;
  except
    g.Free;
    raise;
  end;

  if FGraphPlaying and (App <> nil) and (App.Audio <> nil) then
    App.Audio.SetSource(g.AsSource);   // swap the live source to the new graph

  FGraph.Free;
  FGraph := g;
  Logger.Info('ui', 'audio graph built: preset ' + IntToStr(cboGraphPreset.ItemIndex));
  RunGraphAnalysis;
end;

procedure TfrmMain.RunGraphAnalysis;
var
  sb: TStringBuilder;
  res: TOfflineResult;
  rms: TRmsMeter;
  tp: TTruePeakMeter;
  loud: TLoudnessMeter;
  i: Integer;
  fr: array[0..1] of Single;
  node: TAudioNode;
begin
  if FGraph = nil then
  begin
    memGraph.Lines.Text := '(choose a preset and press Build)';
    pbGraph.Invalidate;
    Exit;
  end;

  sb := TStringBuilder.Create;
  try
    sb.AppendLine(FGraph.Describe);
    sb.AppendLine;

    if FGraphPlaying then
    begin
      sb.AppendLine('routing LIVE through the device engine');
      if (App <> nil) and (App.Audio <> nil) then
        sb.AppendLine(Format('engine out peak: L %6.1f dBFS   R %6.1f dBFS',
          [LinearToDb(App.Audio.OutputPeak(0)), LinearToDb(App.Audio.OutputPeak(1))]));
      for i := 0 to FGraph.NodeCount - 1 do
      begin
        node := FGraph.GetNode(i);
        if node is TMeterNode then
          sb.AppendLine(Format('meter "%s": peak %6.1f  rms %6.1f  truepeak %6.1f dBTP  M %6.1f LUFS',
            [node.Name, TMeterNode(node).PeakDb, TMeterNode(node).RmsDb,
             TMeterNode(node).TruePeakDb, TMeterNode(node).MomentaryLufs]));
      end;
    end
    else
    begin
      { deterministic offline render of one second through the compiled graph }
      res := RenderSourceOffline(FGraph.AsSource, 48000, 2, 48000, 512);
      rms.Init(48000, 400);
      tp.Init(48000, 4, 24);
      loud := TLoudnessMeter.Create(48000, 2);
      try
        for i := 0 to res.Frames - 1 do
        begin
          rms.Push(res.Planar[0][i]);
          tp.Push(res.Planar[0][i]);
          fr[0] := res.Planar[0][i];
          fr[1] := res.Planar[1][i];
          loud.PushFrame(fr);
        end;
        sb.AppendLine('offline render (1 s, 48 kHz, deterministic):');
        sb.AppendLine(Format('  peak L/R          : %6.2f / %6.2f dBFS',
          [LinearToDb(ChannelPeak(res, 0)), LinearToDb(ChannelPeak(res, 1))]));
        sb.AppendLine(Format('  RMS (400 ms)      : %6.2f dBFS', [rms.ValueDb]));
        sb.AppendLine(Format('  true peak (4x)     : %6.2f dBTP', [tp.ValueDb]));
        sb.AppendLine(Format('  integrated loudness: %6.2f LUFS', [loud.Integrated]));
      finally
        loud.Free;
      end;
    end;

    memGraph.Lines.Text := sb.ToString;
  finally
    sb.Free;
  end;
  pbGraph.Invalidate;
end;

procedure TfrmMain.btnGraphBuildClick(Sender: TObject);
begin
  BuildGraphPreset;
end;

procedure TfrmMain.btnGraphPlayClick(Sender: TObject);
begin
  if (App = nil) or (App.Audio = nil) then Exit;
  if FGraph = nil then
    BuildGraphPreset;
  if FGraph = nil then Exit;

  FGraphPlaying := not FGraphPlaying;
  if FGraphPlaying then
  begin
    FTonePlaying := False;
    StopTimelinePlayback;
    App.Audio.SetSource(FGraph.AsSource);
    mnuGraphPlay.Caption := 'Stop graph';
    pmGraphPlay.Caption := 'Stop graph';
    Logger.Info('ui', 'audio graph routed to device engine');
  end
  else
  begin
    App.Audio.ClearSource;
    mnuGraphPlay.Caption := 'Play graph';
    pmGraphPlay.Caption := 'Play graph';
    Logger.Info('ui', 'audio graph disconnected from device engine');
  end;
  RunGraphAnalysis;
end;

procedure TfrmMain.chkGraphLiveClick(Sender: TObject);
begin
  if chkGraphLive.Checked then
    RunGraphAnalysis;
end;

procedure TfrmMain.pbGraphPaint(Sender: TObject);
var
  c: TCanvas;
  w, h, n, cols, i, j, col, row, bx, by, bw, bh, gapx, gapy: Integer;
  kindId, nm: string;
  srcs: TArray<Integer>;
  lvl: Double;
  cx1, cy1, cx2, cy2: Integer;

  procedure BoxRect(AIndex: Integer; out ABX, ABY: Integer);
  begin
    ABX := 12 + (AIndex mod cols) * (bw + gapx);
    ABY := 12 + (AIndex div cols) * (bh + gapy);
  end;

begin
  c := pbGraph.Canvas;
  w := pbGraph.Width;
  h := pbGraph.Height;
  c.Brush.Color := clWhite;
  c.FillRect(Rect(0, 0, w, h));

  if (FGraph = nil) or (not FGraph.IsCompiled) then
  begin
    c.Font.Color := clGray;
    c.TextOut(12, 12, 'no compiled graph - choose a preset and press Build');
    Exit;
  end;

  n := FGraph.CompiledStepCount;
  if n <= 0 then Exit;

  bw := 150; bh := 46; gapx := 34; gapy := 26;
  cols := (w - 24 + gapx) div (bw + gapx);
  if cols < 1 then cols := 1;

  { edges first }
  c.Pen.Color := clSilver;
  for i := 0 to n - 1 do
  begin
    FGraph.CompiledStep(i, kindId, nm, srcs);
    BoxRect(i, bx, by);
    cx2 := bx; cy2 := by + bh div 2;
    for j := 0 to High(srcs) do
    begin
      BoxRect(srcs[j], col, row);
      cx1 := col + bw; cy1 := row + bh div 2;
      c.MoveTo(cx1, cy1);
      c.LineTo(cx2, cy2);
    end;
  end;

  { boxes }
  for i := 0 to n - 1 do
  begin
    FGraph.CompiledStep(i, kindId, nm, srcs);
    BoxRect(i, bx, by);
    if kindId = 'output' then c.Brush.Color := $00E8F0E0
    else if kindId = 'source' then c.Brush.Color := $00F0E8E0
    else if kindId = 'meter' then
    begin
      lvl := FGraph.CompiledStepLevelDb(i);
      if lvl > -6 then c.Brush.Color := $00A0E0FF
      else if lvl > -24 then c.Brush.Color := $00C8F0FF
      else c.Brush.Color := $00ECF6FF;
    end
    else c.Brush.Color := $00F4F4F4;
    c.Pen.Color := clGray;
    c.Rectangle(bx, by, bx + bw, by + bh);
    c.Brush.Style := bsClear;
    c.Font.Color := clBlack;
    c.TextOut(bx + 6, by + 5, Format('%d. %s', [i, kindId]));
    c.Font.Color := clGrayText;
    c.TextOut(bx + 6, by + 24, nm);
    if kindId = 'meter' then
      c.TextOut(bx + 6, by + 24,
        Format('%s  %.0f dB', [nm, FGraph.CompiledStepLevelDb(i)]));
    c.Brush.Style := bsSolid;
  end;
end;

{ ---- Project system demo (Phase 5): document + versioned save/open,
       undo/redo through the command manager, and autosave/crash recovery.
       Every control is design-time. ---- }

procedure TfrmMain.ReportProjectError(const AWhat: string; E: Exception);
begin
  Logger.Error('ui', AWhat + ': ' + E.Message);
  memProject.Lines.Insert(0, AWhat + ' FAILED: ' + E.Message);
end;

procedure TfrmMain.RefreshProjectTab;
var
  sb: TStringBuilder;
begin
  if FProject = nil then Exit;

  if FProject.FileName = '' then
    lblProjectFile.Caption := '(untitled - not saved)'
  else
    lblProjectFile.Caption := FProject.FileName +
      IfThen(FProject.Dirty, '  *modified*', '');

  if not edtProjectName.Focused then
    edtProjectName.Text := FProject.Name;
  if not edtProjectAuthor.Focused then
    edtProjectAuthor.Text := FProject.Author;
  if not edtProjectTempo.Focused then
    edtProjectTempo.Text := FormatFloat('0.###', FProject.TempoBPM);
  if not edtTimeSigNum.Focused then
    edtTimeSigNum.Text := IntToStr(FProject.TimeSigNum);
  if not edtTimeSigDen.Focused then
    edtTimeSigDen.Text := IntToStr(FProject.TimeSigDen);
  if not edtProjectChannels.Focused then
    edtProjectChannels.Text := IntToStr(FProject.Channels);
  cboProjectSampleRate.ItemIndex := cboProjectSampleRate.Items.IndexOf(IntToStr(FProject.SampleRate));

  mnuProjectUndo.Enabled := FCmds.CanUndo;
  pmProjectUndo.Enabled := FCmds.CanUndo;
  if FCmds.CanUndo then
  begin
    mnuProjectUndo.Caption := 'Undo: ' + FCmds.UndoDescription;
    pmProjectUndo.Caption := mnuProjectUndo.Caption;
  end
  else
  begin
    mnuProjectUndo.Caption := 'Undo';
    pmProjectUndo.Caption := 'Undo';
  end;
  mnuProjectRedo.Enabled := FCmds.CanRedo;
  pmProjectRedo.Enabled := FCmds.CanRedo;
  if FCmds.CanRedo then
  begin
    mnuProjectRedo.Caption := 'Redo: ' + FCmds.RedoDescription;
    pmProjectRedo.Caption := mnuProjectRedo.Caption;
  end
  else
  begin
    mnuProjectRedo.Caption := 'Redo';
    pmProjectRedo.Caption := 'Redo';
  end;

  mnuProjectRecover.Enabled := (FProject.FileName <> '') and
    FRecovery.HasUncleanShutdown(FProject.FileName);
  pmProjectRecover.Enabled := mnuProjectRecover.Enabled;

  sb := TStringBuilder.Create;
  try
    sb.AppendLine(FProject.Describe);
    sb.AppendLine;
    sb.AppendLine(Format('undo stack: %d   redo stack: %d', [FCmds.UndoCount, FCmds.RedoCount]));
    sb.AppendLine(Format('autosave: %s   backups on disk: %s',
      [AutosaveIntervalName(FRecovery.Interval),
       IfThen(FProject.FileName <> '', IntToStr(FRecovery.AutosaveCount(FProject.FileName)), '0')]));
    memProject.Lines.Text := sb.ToString;
  finally
    sb.Free;
  end;
end;

procedure TfrmMain.ProjectTick;
begin
  if (FProject = nil) or (FRecovery = nil) or not FRecoverySessionActive then Exit;
  try
    CaptureOpenWindowLayout;
    FRecovery.Tick(FProject, Now);
  except
    on E: Exception do
      Logger.LogException('ui', E, 'autosave tick');
  end;
end;

procedure TfrmMain.RefreshRecentProjects;
var i: Integer; path: string; item: TMenuItem;
begin
  mnuProjectRecent.Clear;
  for i := 0 to 9 do
  begin
    path := App.Config.GetString('project', 'recent_' + IntToStr(i), '');
    if path = '' then Continue;
    item := TMenuItem.Create(mnuProjectRecent);
    item.Caption := IntToStr(i + 1) + '. ' + StringReplace(path, '&', '&&', [rfReplaceAll]);
    item.Hint := path;
    item.OnClick := RecentProjectClick;
    mnuProjectRecent.Add(item);
  end;
  mnuProjectRecent.Enabled := mnuProjectRecent.Count > 0;
end;

procedure TfrmMain.RememberProject(const AFileName: string);
begin
  RememberRecentProject(App.Config, AFileName);
  if not App.Config.Save then Logger.Warn('ui', 'Could not persist recent projects');
  RefreshRecentProjects;
end;

procedure TfrmMain.RestoreStartupProject;
var path: string;
begin
  RefreshRecentProjects;
  path := App.Config.GetString('project', 'last_project', '');
  if path = '' then Exit;
  try
    OpenProjectFile(path, FRecovery.HasUncleanShutdown(path));
  except
    on E: Exception do ReportProjectError('Restore last project', E);
  end;
end;

procedure TfrmMain.RecentProjectClick(Sender: TObject);
var path: string;
begin
  if FProject.Dirty and (MessageDlg('Discard unsaved changes and open another project?',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes) then Exit;
  path := TMenuItem(Sender).Hint;
  try
    OpenProjectFile(path, FRecovery.HasUncleanShutdown(path));
    pgc.ActivePage := tabProject;
    pgcChange(pgc);
  except
    on E: Exception do ReportProjectError('Recent project', E);
  end;
end;

procedure TfrmMain.OpenProjectFile(const AFileName: string; AAsRecovery: Boolean);
var
  newDoc: TProjectDocument;
  tl: TTimeline;
  i, srcCount: Integer;
begin
  if FRecWriter <> nil then
  begin
    MessageDlg('Stop live recording before changing the project or audio input.', mtInformation, [mbOK], 0);
    Exit;
  end;

  { Free everything up first - every running transport, the old project's
    players/decode caches, and the document itself - before a single byte
    of the new project is read, rather than loading the replacement doc
    alongside whatever the old one still had live. }
  StopAllPlayback;
  { VST2 editors are tied to a specific mixer insert of the OLD project - a
    strip/insert index pair that means nothing once FProject is replaced.
    Close them first (this also captures their final geometry into the old
    document's window layout via VST2EditorClosing, for whatever that is
    still worth). Log Viewer / Browser Window are app-level, not
    project-specific, so they are left as-is across the switch. }
  while (FOpenVST2Editors <> nil) and (FOpenVST2Editors.Count > 0) do
    FOpenVST2Editors[0].Close;
  if FSunoJob <> nil then FSunoJob.Cancel;
  FSunoJob := nil;
  if FLumaJob <> nil then FLumaJob.Cancel;
  FLumaJob := nil;
  if FRecoverySessionActive then
  begin
    FRecovery.EndSessionClean;
    FRecoverySessionActive := False;
  end;
  FCmds.Clear;
  FreeAndNil(FProject);
  FTlWaveformWarned.Clear;

  ShowStatusProgress('Loading project ' + ExtractFileName(AFileName) + '...', 100);
  try
    try
      UpdateStatusProgress(0, 'Reading project file...');
      if AAsRecovery then
        newDoc := FRecovery.RecoverNewest(AFileName)
      else
        newDoc := LoadProjectFromFile(AFileName);
      FProject := newDoc;
      UpdateStatusProgress(35, 'Project file read.');

      { Render the timeline: warm every source's waveform peak cache up front
        (with progress), rather than leaving it to build lazily and silently,
        one clip at a time, the first time pbTimelinePaint touches it. }
      tl := FProject.Timeline;
      srcCount := tl.SourceCount;
      for i := 0 to srcCount - 1 do
      begin
        UpdateStatusProgress(35 + Round(i / Max(1, srcCount) * 65),
          Format('Rendering timeline (%d/%d)...', [i + 1, srcCount]));
        WarmClipWaveform(tl.GetSource(i).Id,
          35 + Round(i / Max(1, srcCount) * 65), Round(65 / Max(1, srcCount)), False);
      end;
      UpdateStatusProgress(100, 'Project loaded.');
    except
      { Loading failed after the old project was already freed - never leave
        FProject nil for the rest of the session (most of the UI assumes a
        live project), fall back to a blank one and let the caller's own
        try/except (RecentProjectClick/RestoreStartupProject/
        btnProjectOpenClick) report the real error to the user. }
      if FProject = nil then FProject := TProjectDocument.CreateNew;
      raise;
    end;
  finally
    HideStatusProgress;
  end;

  FTlSelectedTrackId := -1;
  FTlCtxTrackId := -1;
  FTlSelClipId := -1;
  FTlSelClipIds := nil;
  FTlExtraTrackIds := nil;
  FTlRangeActive := False;
  FreeAndNil(FTlCacheHolder);   // source ids belong to the old project
  FRecInsertSeconds := 0;

  FRecovery.BeginSession(AFileName);
  FRecoverySessionActive := True;

  Logger.Info('ui', 'project opened: ' + AFileName + IfThen(AAsRecovery, ' (recovered)', ''));
  RememberProject(AFileName);
  FMidiClipIndex := -1;
  FMidiTrackIndex := 0;
  RefreshProjectTab;
  RefreshMidiTab;
  RefreshTimelineTab;
  RestoreWindowLayout;
end;

procedure TfrmMain.btnProjectNewClick(Sender: TObject);
begin
  if FRecWriter <> nil then
  begin
    MessageDlg('Stop live recording before changing the project or audio input.', mtInformation, [mbOK], 0);
    Exit;
  end;
  if FProject.Dirty then
    if MessageDlg('Discard unsaved changes and start a new project?', mtConfirmation,
      [mbYes, mbNo], 0) <> mrYes then
      Exit;

  StopAllPlayback;
  while (FOpenVST2Editors <> nil) and (FOpenVST2Editors.Count > 0) do
    FOpenVST2Editors[0].Close;
  if FRecoverySessionActive then
  begin
    FRecovery.EndSessionClean;
    FRecoverySessionActive := False;
  end;
  FCmds.Clear;
  FreeAndNil(FProject);
  FTlWaveformWarned.Clear;
  FProject := TProjectDocument.CreateNew;
  FTlSelectedTrackId := -1;
  FTlCtxTrackId := -1;
  FTlSelClipId := -1;
  FTlSelClipIds := nil;
  FTlExtraTrackIds := nil;
  FTlRangeActive := False;
  FreeAndNil(FTlCacheHolder);
  FRecInsertSeconds := 0;
  if FSunoJob <> nil then FSunoJob.Cancel;
  FSunoJob := nil;
  if FLumaJob <> nil then FLumaJob.Cancel;
  FLumaJob := nil;
  App.Config.SetString('project', 'last_project', '');
  App.Config.Save;
  FMidiClipIndex := -1;
  FMidiTrackIndex := 0;
  Logger.Info('ui', 'new project created');
  RefreshProjectTab;
  RefreshMidiTab;
  RefreshTimelineTab;
end;

procedure TfrmMain.btnProjectOpenClick(Sender: TObject);
begin
  if not dlgOpenProject.Execute then Exit;
  try
    if FRecovery.HasUncleanShutdown(dlgOpenProject.FileName) and
      (MessageDlg('This project has unsaved changes from a previous session ' +
        'that did not close cleanly. Recover them?', mtConfirmation, [mbYes, mbNo], 0) = mrYes) then
      OpenProjectFile(dlgOpenProject.FileName, True)
    else
      OpenProjectFile(dlgOpenProject.FileName, False);
  except
    on E: Exception do
      ReportProjectError('Open', E);
  end;
end;

{ Commits the Name field immediately (on leaving it, and before any save)
  instead of waiting for "Apply metadata" - otherwise the next
  RefreshProjectTab overwrote the typed text with the old name. }
procedure TfrmMain.edtProjectNameExit(Sender: TObject);
begin
  if (FProject = nil) or (Trim(edtProjectName.Text) = '') then Exit;
  if Trim(edtProjectName.Text) <> FProject.Name then
    try
      FCmds.Perform(TSetProjectNameCommand.Create(FProject, Trim(edtProjectName.Text)));
    except
      on E: Exception do
        ReportProjectError('Rename project', E);
    end;
end;

{ Author's name (stamped into MP3/MP4/M4A exports) - committed like the Name
  field: on leaving it, and before any save. }
procedure TfrmMain.edtProjectAuthorExit(Sender: TObject);
begin
  if FProject = nil then Exit;
  if Trim(edtProjectAuthor.Text) <> FProject.Author then
    try
      FCmds.Perform(TSetProjectAuthorCommand.Create(FProject, Trim(edtProjectAuthor.Text)));
    except
      on E: Exception do
        ReportProjectError('Set author', E);
    end;
end;

procedure TfrmMain.btnProjectSaveClick(Sender: TObject);
begin
  edtProjectNameExit(nil);
  edtProjectAuthorExit(nil);
  if FProject.FileName = '' then
  begin
    btnProjectSaveAsClick(Sender);
    Exit;
  end;
  try
    CaptureOpenWindowLayout;
    SaveProjectToFile(FProject, FProject.FileName);
    RememberProject(FProject.FileName);
    if not FRecoverySessionActive then
    begin
      FRecovery.BeginSession(FProject.FileName);
      FRecoverySessionActive := True;
    end;
    Logger.Info('ui', 'project saved: ' + FProject.FileName);
    RefreshProjectTab;
  except
    on E: Exception do
      ReportProjectError('Save', E);
  end;
end;

procedure TfrmMain.btnProjectSaveAsClick(Sender: TObject);
begin
  edtProjectNameExit(nil);
  edtProjectAuthorExit(nil);
  if FProject.FileName <> '' then
    dlgSaveProject.FileName := FProject.FileName
  else
    dlgSaveProject.FileName := FProject.Name + PROJECT_FILE_EXT;
  if not dlgSaveProject.Execute then Exit;
  try
    if FRecoverySessionActive then
      FRecovery.EndSessionClean;
    CaptureOpenWindowLayout;
    SaveProjectToFile(FProject, dlgSaveProject.FileName);
    RememberProject(FProject.FileName);
    FRecovery.BeginSession(FProject.FileName);
    FRecoverySessionActive := True;
    Logger.Info('ui', 'project saved as: ' + FProject.FileName);
    RefreshProjectTab;
  except
    on E: Exception do
      ReportProjectError('Save As', E);
  end;
end;

procedure TfrmMain.btnProjectApplyClick(Sender: TObject);
var
  tempo: Double;
  tsNum, tsDen, sr, ch: Integer;
begin
  try
    if Trim(edtProjectName.Text) <> FProject.Name then
      FCmds.Perform(TSetProjectNameCommand.Create(FProject, Trim(edtProjectName.Text)));
    edtProjectAuthorExit(nil);

    if TryStrToFloat(edtProjectTempo.Text, tempo) and (tempo <> FProject.TempoBPM) then
      FCmds.Perform(TSetTempoCommand.Create(FProject, tempo));

    if TryStrToInt(edtTimeSigNum.Text, tsNum) and TryStrToInt(edtTimeSigDen.Text, tsDen) and
      ((tsNum <> FProject.TimeSigNum) or (tsDen <> FProject.TimeSigDen)) then
      FCmds.Perform(TSetTimeSignatureCommand.Create(FProject, tsNum, tsDen));

    { sample rate / channel count are project-format settings, not undoable
      edits (there is no audio content yet whose undo history they belong to) }
    if TryStrToInt(cboProjectSampleRate.Text, sr) and (sr <> FProject.SampleRate) then
      FProject.SampleRate := sr;
    if TryStrToInt(edtProjectChannels.Text, ch) and (ch <> FProject.Channels) then
      FProject.Channels := ch;

    RefreshProjectTab;
  except
    on E: Exception do
      ReportProjectError('Apply metadata', E);
  end;
end;

procedure TfrmMain.btnUndoClick(Sender: TObject);
begin
  FCmds.Undo;
  RefreshProjectTab;
end;

procedure TfrmMain.btnRedoClick(Sender: TObject);
begin
  FCmds.Redo;
  RefreshProjectTab;
end;

procedure TfrmMain.btnAddGainNodeClick(Sender: TObject);
begin
  FCmds.Perform(TAddGraphNodeCommand.Create(FProject, nkGain,
    Format('Gain %d', [FProject.Graph.NodeCount])));
  RefreshProjectTab;
end;

procedure TfrmMain.btnRemoveLastNodeClick(Sender: TObject);
var
  n: TAudioNode;
begin
  if FProject.Graph.NodeCount = 0 then Exit;
  n := FProject.Graph.GetNode(FProject.Graph.NodeCount - 1);
  if n.Kind = nkOutput then
  begin
    memProject.Lines.Insert(0, 'cannot remove the Master output node');
    Exit;
  end;
  FCmds.Perform(TRemoveGraphNodeCommand.Create(FProject, n.Id));
  RefreshProjectTab;
end;

procedure TfrmMain.cboAutosaveIntervalChange(Sender: TObject);
begin
  if cboAutosaveInterval.ItemIndex >= 0 then
    FRecovery.Interval := TAutosaveInterval(cboAutosaveInterval.ItemIndex);
  RefreshProjectTab;
end;

procedure TfrmMain.btnAutosaveNowClick(Sender: TObject);
begin
  if not FRecoverySessionActive then
  begin
    memProject.Lines.Insert(0, 'save the project at least once before autosaving');
    Exit;
  end;
  try
    CaptureOpenWindowLayout;
    FRecovery.AutosaveNow(FProject);
    Logger.Info('ui', 'manual autosave');
    RefreshProjectTab;
  except
    on E: Exception do
      ReportProjectError('Autosave', E);
  end;
end;

procedure TfrmMain.btnRecoverClick(Sender: TObject);
begin
  if FProject.FileName = '' then Exit;
  try
    OpenProjectFile(FProject.FileName, True);
  except
    on E: Exception do
      ReportProjectError('Recover', E);
  end;
end;

{ ---- PCM/WAV engine demo (Phase 6): import a real WAV, probe its header,
       route it through the device engine (rate-adapted), export a generated
       tone in any supported bit depth, and verify a full encode/decode
       round-trip. Every control is design-time. ---- }

function TfrmMain.SelectedWavFormat: TWavSampleFormat;
begin
  case cboWavFormat.ItemIndex of
    0: Result := wsfPCM8;
    2: Result := wsfPCM24;
    3: Result := wsfPCM32;
    4: Result := wsfFloat32;
    5: Result := wsfFloat64;
  else
    Result := wsfPCM16;
  end;
end;

procedure TfrmMain.btnWavImportClick(Sender: TObject);
var
  info: TWavInfo;
begin
  if not dlgOpenWav.Execute then Exit;
  try
    if not FileLooksLikeWav(dlgOpenWav.FileName) then
    begin
      memWav.Lines.Text := 'not a WAV file (header signature check failed):' + sLineBreak +
        dlgOpenWav.FileName;
      mnuWavPlay.Enabled := False;
      pmWavPlay.Enabled := False;
      Exit;
    end;
    info := ReadWavInfo(dlgOpenWav.FileName);
    FWavPath := dlgOpenWav.FileName;
    memWav.Lines.Text :=
      'imported: ' + FWavPath + sLineBreak +
      info.Describe + sLineBreak + sLineBreak +
      'press Play to route it through the device engine';
    mnuWavPlay.Enabled := True;
    pmWavPlay.Enabled := True;
    Logger.Info('ui', 'WAV imported: ' + FWavPath + '  [' + info.Describe + ']');
  except
    on E: Exception do
    begin
      Logger.Error('ui', 'WAV import failed: ' + E.Message);
      memWav.Lines.Text := 'import FAILED: ' + E.Message;
      mnuWavPlay.Enabled := False;
      pmWavPlay.Enabled := False;
    end;
  end;
end;

procedure TfrmMain.btnWavPlayClick(Sender: TObject);
begin
  if (App = nil) or (App.Audio = nil) then Exit;

  if FWavPlaying then
  begin
    App.Audio.ClearSource;
    FWavSource := nil;
    FWavPlaying := False;
    mnuWavPlay.Caption := 'Play';
    pmWavPlay.Caption := 'Play';
    Logger.Info('ui', 'WAV playback stopped');
    Exit;
  end;

  if FWavPath = '' then
  begin
    memWav.Lines.Insert(0, 'import a WAV file first');
    Exit;
  end;

  try
    FWavSource := TWavPlayerSource.Create(FWavPath, chkWavLoop.Checked);
    FTonePlaying := False;
    FGraphPlaying := False;
    StopTimelinePlayback;
    App.Audio.SetSource(FWavSource);
    FWavPlaying := True;
    mnuWavPlay.Caption := 'Stop';
    pmWavPlay.Caption := 'Stop';
    Logger.Info('ui', 'WAV playback started: ' + FWavPath);
  except
    on E: Exception do
    begin
      FWavSource := nil;
      memWav.Lines.Insert(0, 'playback FAILED: ' + E.Message);
    end;
  end;
end;

procedure TfrmMain.btnWavExportToneClick(Sender: TObject);
const
  SR = 48000;
  SECS = 2;
var
  planar: TAudioPlanar;
  i, n: Integer;
  ph: Double;
  fmt: TWavSampleFormat;
begin
  if not RequireRegistration('Exporting audio') then Exit;
  if dlgSaveWav.FileName = '' then
    dlgSaveWav.FileName := 'udaw-testtone.wav';
  if not dlgSaveWav.Execute then Exit;

  fmt := SelectedWavFormat;
  n := SR * SECS;
  SetLength(planar, 2);
  SetLength(planar[0], n);
  SetLength(planar[1], n);
  for i := 0 to n - 1 do
  begin
    ph := 2 * Pi * 440.0 * i / SR;
    planar[0][i] := 0.5 * Sin(ph);
    planar[1][i] := 0.5 * Sin(ph * 1.5);   // a perfect fifth on the right
  end;

  try
    SaveWavFile(dlgSaveWav.FileName, planar, 2, SR, n, fmt);
    memWav.Lines.Text := Format('wrote %s%s(%s, 2 ch, %d Hz, %d frames, %.2f s)',
      [dlgSaveWav.FileName, sLineBreak, WavSampleFormatName(fmt), SR, n, SECS + 0.0]);
    Logger.Info('ui', 'WAV test tone exported: ' + dlgSaveWav.FileName +
      ' (' + WavSampleFormatName(fmt) + ')');
  except
    on E: Exception do
      memWav.Lines.Insert(0, 'export FAILED: ' + E.Message);
  end;
end;

procedure TfrmMain.btnWavRoundTripClick(Sender: TObject);
const
  SR = 48000;
var
  fmt: TWavSampleFormat;
  src, back: TAudioPlanar;
  fn: string;
  i, n, ch2, sr2: Integer;
  ph, maxErr, d: Double;
begin
  fmt := SelectedWavFormat;
  n := SR;   // one second, stereo
  SetLength(src, 2);
  SetLength(src[0], n);
  SetLength(src[1], n);
  for i := 0 to n - 1 do
  begin
    ph := 2 * Pi * 220.0 * i / SR;
    src[0][i] := 0.7 * Sin(ph);
    src[1][i] := 0.7 * Sin(ph * 2);
  end;

  fn := IncludeTrailingPathDelimiter(App.Paths.Cache) + 'udaw-wav-roundtrip.wav';
  try
    SaveWavFile(fn, src, 2, SR, n, fmt);
    back := LoadWavFile(fn, ch2, sr2);
    maxErr := 0;
    for i := 0 to n - 1 do
    begin
      d := Abs(src[0][i] - back[0][i]);
      if d > maxErr then maxErr := d;
      d := Abs(src[1][i] - back[1][i]);
      if d > maxErr then maxErr := d;
    end;
    memWav.Lines.Text := Format(
      'round-trip through %s'#13#10 +
      '  file        : %s'#13#10 +
      '  channels    : %d    sample rate : %d'#13#10 +
      '  frames back : %d / %d'#13#10 +
      '  max abs err : %.3e  (%.1f dBFS)',
      [WavSampleFormatName(fmt), fn, ch2, sr2, Length(back[0]), n,
       maxErr, LinearToDb(maxErr + 1.0E-30)]);
    DeleteFile(fn);
    Logger.Info('ui', Format('WAV round-trip %s: max abs err %.3e',
      [WavSampleFormatName(fmt), maxErr]));
  except
    on E: Exception do
      memWav.Lines.Insert(0, 'round-trip FAILED: ' + E.Message);
  end;
end;

{ ---- MP3 (Phase 15): design-time tab.  Import decodes MPEG-1 Layer III to the
       engine planar buffer and reports the stream layout; Read tags parses ID3
       v2/v1; Export encodes a generated stereo tone at the chosen CBR bitrate
       (from-scratch encoder, no LAME); the verify button runs a full
       encode -> decode round-trip in memory.  Every control is placed at design
       time. ---- }

procedure TfrmMain.btnMp3ImportClick(Sender: TObject);
var
  res: TMP3DecodeResult;
  t0: TDateTime;
begin
  if not dlgOpenMp3.Execute then Exit;
  try
    if not Mp3SniffFile(dlgOpenMp3.FileName) then
    begin
      memMp3.Lines.Text := 'not an MP3 (no MPEG-audio sync / ID3 tag):'#13#10 +
        dlgOpenMp3.FileName;
      Exit;
    end;
    t0 := Now;
    if not Mp3DecodeFile(dlgOpenMp3.FileName, res, True) then
    begin
      memMp3.Lines.Text := 'decode produced no audio: ' + dlgOpenMp3.FileName;
      Exit;
    end;
    memMp3.Lines.Text := Format(
      'decoded %s'#13#10 +
      '  %s'#13#10 +
      '  channels    : %d    sample rate : %d Hz'#13#10 +
      '  frames      : %d  (%.2f s)'#13#10 +
      '  decoded/LSF : %d / %d    clipped samples : %d'#13#10 +
      '  decode time : %.0f ms',
      [dlgOpenMp3.FileName, res.Info.Describe, res.Channels, res.SampleRate,
       res.Frames, res.Frames / Max(1, res.SampleRate),
       res.DecodedFrames, res.SkippedLsfFrames, res.ClippedSamples,
       (Now - t0) * 24 * 60 * 60 * 1000]);
    Logger.Info('ui', 'MP3 import: ' + dlgOpenMp3.FileName);
  except
    on E: Exception do
      memMp3.Lines.Insert(0, 'import FAILED: ' + E.Message);
  end;
end;

procedure TfrmMain.btnMp3ReadTagsClick(Sender: TObject);
var
  meta: TMP3Metadata;
begin
  if not dlgOpenMp3.Execute then Exit;
  try
    meta := Mp3ReadMetadataFile(dlgOpenMp3.FileName);
    memMp3.Lines.Text := Format(
      'ID3 tags for %s'#13#10 +
      '  v2 present  : %s      v1 present : %s'#13#10 +
      '  title       : %s'#13#10 +
      '  artist      : %s'#13#10 +
      '  album       : %s'#13#10 +
      '  album artist: %s'#13#10 +
      '  composer    : %s'#13#10 +
      '  year        : %s      track : %s'#13#10 +
      '  genre       : %s'#13#10 +
      '  comment     : %s',
      [dlgOpenMp3.FileName, BoolToStr(meta.HasV2, True), BoolToStr(meta.HasV1, True),
       meta.Title, meta.Artist, meta.Album, meta.AlbumArtist, meta.Composer,
       meta.Year, meta.TrackNumber, meta.Genre, meta.Comment]);
  except
    on E: Exception do
      memMp3.Lines.Insert(0, 'tag read FAILED: ' + E.Message);
  end;
end;

function TfrmMain.Mp3TabTone(AFreqL, AFreqR: Double; AFrames: Integer): TAudioPlanar;
var
  i: Integer;
  ph: Double;
begin
  SetLength(Result, 2);
  SetLength(Result[0], AFrames);
  SetLength(Result[1], AFrames);
  for i := 0 to AFrames - 1 do
  begin
    ph := 2 * Pi * i / 44100.0;
    Result[0][i] := 0.55 * Sin(ph * AFreqL);
    Result[1][i] := 0.55 * Sin(ph * AFreqR);
  end;
end;

procedure TfrmMain.btnMp3ExportToneClick(Sender: TObject);
var
  opt: TMP3EncodeOptions;
  pcm: TAudioPlanar;
  res: TMP3EncodeResult;
  fs: TFileStream;
  meta: TMP3Metadata;
  tag: TBytes;
begin
  if not RequireRegistration('Exporting MP3') then Exit;
  if dlgSaveMp3.FileName = '' then dlgSaveMp3.FileName := 'udaw-testtone.mp3';
  if not dlgSaveMp3.Execute then Exit;
  pcm := Mp3TabTone(440, 660, 44100 * 2);
  opt := Mp3DefaultEncodeOptions;
  opt.Mode := emCBR;
  opt.BitrateKbps := StrToIntDef(Trim(cboMp3Bitrate.Text), 192);
  try
    if not Mp3Encode(pcm, 44100, opt, res) then
    begin
      memMp3.Lines.Text := 'encode produced no data';
      Exit;
    end;
    meta.Clear;
    meta.Copyright := UDAW_MEDIA_COPYRIGHT;
    tag := BuildId3v2Tag(meta);
    fs := TFileStream.Create(dlgSaveMp3.FileName, fmCreate);
    try
      fs.WriteBuffer(tag[0], Length(tag));
      if Length(res.Data) > 0 then fs.WriteBuffer(res.Data[0], Length(res.Data));
    finally
      fs.Free;
    end;
    memMp3.Lines.Text := Format(
      'wrote %s'#13#10 +
      '  %d frames, %d bytes, ~%.1f kbps (CBR %d)',
      [dlgSaveMp3.FileName, res.FrameCount, res.ByteCount, res.AvgBitrateKbps,
       opt.BitrateKbps]);
    Logger.Info('ui', 'MP3 test tone exported: ' + dlgSaveMp3.FileName);
  except
    on E: Exception do
      memMp3.Lines.Insert(0, 'export FAILED: ' + E.Message);
  end;
end;

procedure TfrmMain.btnMp3RoundTripClick(Sender: TObject);
var
  opt: TMP3EncodeOptions;
  pcm: TAudioPlanar;
  eres: TMP3EncodeResult;
  dres: TMP3DecodeResult;
  domL, domR: Double;

  function DomFreqCh(const P: TAudioPlanar; c, a, b: Integer): Double;
  var
    k, fx, lx, cr: Integer;
    pv, cv: Single;
  begin
    Result := 0; fx := -1; lx := -1; cr := 0;
    if a < 1 then a := 1;
    if b > Length(P[c]) then b := Length(P[c]);
    pv := P[c][a - 1];
    for k := a to b - 1 do
    begin
      cv := P[c][k];
      if (pv <= 0) and (cv > 0) then
      begin
        if fx < 0 then fx := k;
        lx := k; Inc(cr);
      end;
      pv := cv;
    end;
    if (cr >= 2) and (lx > fx) then Result := (cr - 1) * 44100.0 / (lx - fx);
  end;

begin
  pcm := Mp3TabTone(440, 1500, 44100 * 2);
  opt := Mp3DefaultEncodeOptions;
  opt.Mode := emCBR;
  opt.BitrateKbps := StrToIntDef(Trim(cboMp3Bitrate.Text), 256);
  try
    if not Mp3Encode(pcm, 44100, opt, eres) then
    begin memMp3.Lines.Text := 'encode failed'; Exit; end;
    if not Mp3Decode(eres.Data, dres, False) then
    begin memMp3.Lines.Text := 'decode of the encoded stream failed'; Exit; end;
    domL := DomFreqCh(dres.Pcm, 0, 2000, dres.Frames - 2000);
    domR := DomFreqCh(dres.Pcm, 1, 2000, dres.Frames - 2000);
    memMp3.Lines.Text := Format(
      'encode -> decode round-trip (CBR %d kbps)'#13#10 +
      '  encoded : %d frames, %d bytes'#13#10 +
      '  decoded : %d frames'#13#10 +
      '  dominant L : %.1f Hz   (fed 440 Hz)'#13#10 +
      '  dominant R : %.1f Hz   (fed 1500 Hz)',
      [opt.BitrateKbps, eres.FrameCount, eres.ByteCount, dres.Frames, domL, domR]);
  except
    on E: Exception do
      memMp3.Lines.Insert(0, 'round-trip FAILED: ' + E.Message);
  end;
end;

{ Import the selected MP3 onto the timeline as an undoable non-destructive clip
  (Phase 15 follow-up: TImportMp3Command), mirroring the WAV add-clip path. }
procedure TfrmMain.btnMp3ToTimelineClick(Sender: TObject);
var
  tl: TTimeline;
  trackId: Integer;
  cmd: TImportMp3Command;
begin
  if FProject = nil then
  begin
    memMp3.Lines.Insert(0, 'open or create a project first');
    Exit;
  end;
  if not dlgOpenMp3.Execute then Exit;
  try
    if not Mp3SniffFile(dlgOpenMp3.FileName) then
    begin
      memMp3.Lines.Insert(0, 'not an MP3: ' + dlgOpenMp3.FileName);
      Exit;
    end;
    tl := FProject.Timeline;
    trackId := TlNewAudioTrackId;

    cmd := TImportMp3Command.Create(FProject, trackId, dlgOpenMp3.FileName,
      FTlView.Snap(tl.PlayheadSeconds), 0);
    FCmds.Perform(cmd);
    WarmClipWaveform(cmd.SourceId);
    FMp3Path := dlgOpenMp3.FileName;
    memMp3.Lines.Text := Format(
      'imported onto timeline: %s'#13#10 +
      '  %d Hz, %d ch, %.3f s  (clip id %d)',
      [dlgOpenMp3.FileName, cmd.ImportedSampleRate, cmd.ImportedChannels,
       cmd.ImportedLengthSeconds, cmd.CreatedClipId]);
    Logger.Info('ui', 'MP3 imported to timeline: ' + dlgOpenMp3.FileName);
    ApplyBaselineTempoOnImport(cmd.CreatedClipId);
    RefreshTimelineTab;
  except
    on E: Exception do
      memMp3.Lines.Insert(0, 'timeline import FAILED: ' + E.Message);
  end;
end;

{ Audition an MP3 straight through the audio engine with a seekable streaming
  source (Phase 15 follow-up: TMP3StreamSource). }
procedure TfrmMain.btnMp3PlayClick(Sender: TObject);
var
  fn, wavDump: string;
  src: TMP3StreamSource;
  devRate: Integer;
begin
  { always let the user pick - default the dialog to the last file }
  if (FMp3Path <> '') and FileExists(FMp3Path) then
    dlgOpenMp3.FileName := FMp3Path;
  if not dlgOpenMp3.Execute then Exit;
  fn := dlgOpenMp3.FileName;
  try
    if not Mp3SniffFile(fn) then
    begin
      memMp3.Lines.Insert(0, 'not an MP3: ' + fn);
      Exit;
    end;
    FMp3Path := fn;
    src := TMP3StreamSource.CreateFromFile(fn, False);
    FMp3Source := src;

    { diagnostic: dump the fully-decoded PCM (what Render reads from, before any
      rate adaptation) so it can be A/B'd against the engine playback }
    wavDump := IncludeTrailingPathDelimiter(GetEnvironmentVariable('TEMP')) +
      'udaw-mp3-decoded.wav';
    try
      { first 30 s is plenty to judge muffling and keeps the encode small }
      src.SaveDecodedWav(wavDump, 30 * src.SourceRate);
    except
      on E: Exception do wavDump := '(dump failed: ' + E.Message + ')';
    end;

    devRate := 0;
    if App <> nil then
    begin
      devRate := App.Audio.Granted.SampleRate;
      App.Audio.SetSource(FMp3Source);
    end;

    memMp3.Lines.Text := Format(
      'playing through the engine: %s'#13#10 +
      '  %s'#13#10 +
      '  file rate  : %d Hz'#13#10 +
      '  device rate: %d Hz   %s'#13#10 +
      '  decoded PCM written to: %s'#13#10 +
      '  (open that WAV in an external player: if IT is muffled the decoder is '#13#10 +
      '   the cause; if it is clean the resampler/engine is.)',
      [fn, src.Name, src.SourceRate, devRate,
       IfThen(devRate = src.SourceRate, '(matches file - no resampling)',
                                        '(differs - Render resamples)'),
       wavDump]);
    Logger.Info('ui', Format('MP3 streaming source started: %s (file %d Hz, device %d Hz)',
      [fn, src.SourceRate, devRate]));
  except
    on E: Exception do
    begin
      FMp3Source := nil;
      memMp3.Lines.Insert(0, 'play FAILED: ' + E.Message);
    end;
  end;
end;

procedure TfrmMain.btnMp3StopClick(Sender: TObject);
begin
  if App <> nil then
    App.Audio.ClearSource;
  FMp3Source := nil;
  memMp3.Lines.Insert(0, 'playback stopped');
end;

{ ---- Timeline (Phase 7): design-time tab. Tracks / clips / non-destructive
       editing / zoom / scroll / snap, with real multiresolution waveform
       rendering from the peak cache. Every control is placed at design time;
       only the ruler, lanes, clips and waveforms are painted at run time.
       Timeline edits go through the shared project command manager, so they
       land on the same undo/redo stack as the Project tab. ---- }

function TfrmMain.TimelineGrid: TGridContext;
begin
  if FProject <> nil then
    Result := FProject.GridContext
  else
    Result := TGridContext.Make(120, 4, 4, 48000);
end;

function TfrmMain.TlLaneWidth: Integer;
begin
  Result := pbTimeline.Width - FTlView.HeaderWidth;
  if Result < 1 then Result := 1;
end;

{ Returns the top of track AIndex's own header/lane CONTENT - i.e. just below
  that track's own title band (FTlView.TrackTitleHeight), which sits between
  the previous track's content and this one and is drawn/hit-tested
  separately (see TlTrackTitleRect). Every existing consumer of TlTrackTop
  (clip hit-testing, drag/trim, fade handles, track-height resize, ...)
  keeps working unchanged because the title band is entirely "above" the
  value this returns, never inside it. }
function TfrmMain.TlTrackTop(AIndex: Integer): Integer;
var
  i: Integer;
begin
  Result := FTlView.RulerHeight - FTlVScrollY;
  for i := 0 to AIndex - 1 do
    Inc(Result, FTlView.TrackTitleHeight + FProject.Timeline.GetTrack(i).Height);
  Inc(Result, FTlView.TrackTitleHeight);
end;

{ Total pixel height of every track's own title band + content, i.e. the
  vertical extent sbTlVert needs to be able to scroll across. }
function TfrmMain.TlTracksContentHeight: Integer;
var
  i: Integer;
begin
  Result := 0;
  if FProject = nil then Exit;
  for i := 0 to FProject.Timeline.TrackCount - 1 do
    Inc(Result, FTlView.TrackTitleHeight + FProject.Timeline.GetTrack(i).Height);
end;

{ Fixed rect of the per-track header mute button, shared by pbTimelinePaint
  (drawing it) and pbTimelineMouseDown (hit-testing it) so the two can never
  drift out of sync. }
function TfrmMain.TlMuteButtonRect(ATop: Integer): TRect;
begin
  Result := Rect(4, ATop + 3, 20, ATop + 19);
end;

{ Fixed rect of the "?" (tempo unknown) button, bottom-right of a track header. }
function TfrmMain.TlTempoUnknownRect(ATop, ALaneH: Integer): TRect;
begin
  Result := Rect(FTlView.HeaderWidth - 26, ATop + ALaneH - 21, FTlView.HeaderWidth - 8, ATop + ALaneH - 4);
end;

{ True only for the PRIMARY channel (the first track holding audio) while any of
  its audio clips has no known source tempo - i.e. the baseline BPM could not be
  established. Disappears as soon as every audio clip on it has a SourceBPM. }
function TfrmMain.TlPrimaryTempoUnknown(ATrack: TTimelineTrack): Boolean;
var
  ti, ci: Integer;
  trk: TTimelineTrack;
  hasAudio: Boolean;
begin
  Result := False;
  if (FProject = nil) or (ATrack = nil) then Exit;
  for ti := 0 to FProject.Timeline.TrackCount - 1 do
  begin
    trk := FProject.Timeline.GetTrack(ti);
    hasAudio := False;
    for ci := 0 to trk.ClipCount - 1 do
      if not trk.GetClip(ci).IsMidiClip then hasAudio := True;
    if not hasAudio then Continue;
    { first track with audio = the primary channel }
    if trk <> ATrack then Exit;
    for ci := 0 to trk.ClipCount - 1 do
      if (not trk.GetClip(ci).IsMidiClip) and (trk.GetClip(ci).SourceBPM <= 0) then
        Exit(True);
    Exit;
  end;
end;

{ Baseline tempo rule: when the FIRST audio clip of the project is imported,
  detect its BPM, make it that clip's SourceBPM and set the Timeline BPM to it,
  so the baseline is known and every later clip conforms to it (stretch/shrink on
  Play and export). Any later import, an undetectable tempo (< 4 s, no clear
  rhythm) or the Settings option being off leaves everything as it was - the
  primary channel then shows the "?" button (see TlPrimaryTempoUnknown). }
procedure TfrmMain.ApplyBaselineTempoOnImport(AClipId: Integer);
var
  tl: TTimeline;
  clip: TTimelineClip;
  ti, ci, audioCount: Integer;
  trk: TTimelineTrack;
  player: TTimelinePlayer;
  dec: TDecodedSource;
  bpm: Double;
begin
  if (FProject = nil) or (App = nil) then Exit;
  if not App.Config.GetBool(CFG_SEC_GENERAL, CFG_GEN_TEMPO_AUTO, True) then Exit;
  tl := FProject.Timeline;
  clip := tl.ClipById(AClipId);
  if (clip = nil) or clip.IsMidiClip or (clip.SourceBPM > 0) then Exit;
  audioCount := 0;
  for ti := 0 to tl.TrackCount - 1 do
  begin
    trk := tl.GetTrack(ti);
    for ci := 0 to trk.ClipCount - 1 do
      if not trk.GetClip(ci).IsMidiClip then Inc(audioCount);
  end;
  if audioCount <> 1 then Exit;   // not the first primary audio - leave the baseline alone

  bpm := 0;
  player := TTimelinePlayer.Create(tl);
  try
    ShowStatusProgress('Detecting baseline tempo...', 100);
    try
      player.EnsureSourcesLoaded(
        procedure(AFraction: Double)
        begin
          UpdateStatusProgress(Round(AFraction * 100));
        end);
      dec := player.GetDecodedSource(clip.SourceId);
      if (dec <> nil) and not dec.Failed then
      begin
        if dec.Channels > 1 then
          bpm := EstimateTempoBPM(dec.Data[0], dec.Data[1], dec.FrameCount, dec.SampleRate)
        else
          bpm := EstimateTempoBPM(dec.Data[0], dec.Data[0], dec.FrameCount, dec.SampleRate);
      end;
    finally
      HideStatusProgress;
    end;
  finally
    player.Free;
  end;

  if bpm <= 0 then
  begin
    memTimeline.Lines.Insert(0, Format(
      'Baseline tempo: could not detect a BPM for "%s" - Timeline BPM left at %.2f. ' +
      'Click the "?" on the channel header to enter it.', [clip.Name, FProject.TempoBPM]));
    Exit;
  end;
  FCmds.Perform(TSetTimelineClipSourceBpmCommand.Create(FProject, clip.Id, bpm));
  if Abs(bpm - FProject.TempoBPM) > 0.0005 then
    FCmds.Perform(TSetTempoCommand.Create(FProject, bpm));
  edtTlTempo.Text := FormatFloat('0.###', FProject.TempoBPM);
  memTimeline.Lines.Insert(0, Format(
    'Baseline tempo: "%s" detected at %.2f BPM - Timeline BPM set to %.2f. ' +
    'Later clips conform to it.', [clip.Name, bpm, FProject.TempoBPM]));
end;

{ "?" pressed on the primary channel: ask for the channel's tempo (Clip Tempo
  dialog - number or "auto"), then, since this is the baseline channel, make the
  Timeline BPM that tempo. The "?" vanishes once the tempo is known. }
procedure TfrmMain.TlTempoUnknownClick;
var
  ti, ci: Integer;
  trk: TTimelineTrack;
  bpm: Double;
begin
  if FProject = nil then Exit;
  FTlSelClipId := -1;
  FTlSelClipIds := nil;
  TlClipTempoClick(nil);
  bpm := 0;
  for ti := 0 to FProject.Timeline.TrackCount - 1 do
  begin
    trk := FProject.Timeline.GetTrack(ti);
    if trk.Id <> FTlSelectedTrackId then Continue;
    for ci := 0 to trk.ClipCount - 1 do
      if (not trk.GetClip(ci).IsMidiClip) and (trk.GetClip(ci).SourceBPM > 0) then
      begin
        bpm := trk.GetClip(ci).SourceBPM;
        Break;
      end;
  end;
  if (bpm > 0) and (Abs(bpm - FProject.TempoBPM) > 0.0005) then
  begin
    FCmds.Perform(TSetTempoCommand.Create(FProject, bpm));
    edtTlTempo.Text := FormatFloat('0.###', FProject.TempoBPM);
    memTimeline.Lines.Insert(0, Format('Baseline tempo: Timeline BPM set to %.2f.', [FProject.TempoBPM]));
    RefreshTimelineTab;
  end;
end;

{ The band directly above a track's header/lane content, spanning the full
  timeline width, reserved for that channel's own section/effect-name title
  (TTimelineTrack.Title) - see the comment on TlTrackTop for why this sits
  outside the region every other Tl* helper treats as "the track". }
function TfrmMain.TlTrackTitleRect(ATop, AWidth: Integer): TRect;
begin
  Result := Rect(FTlView.HeaderWidth, ATop - FTlView.TrackTitleHeight, AWidth, ATop);
end;

function TfrmMain.TlExtraTrackIndex(AId: Integer): Integer;
var i: Integer;
begin
  for i := 0 to High(FTlExtraTrackIds) do
    if FTlExtraTrackIds[i] = AId then Exit(i);
  Result := -1;
end;

{ Every selected channel, in order: the primary selected track first (track 0
  when none is selected), then each extra Ctrl/Shift-selected track. Range
  effects run once per entry, one channel after another. }
function TfrmMain.TlRangeTrackIds: TArray<Integer>;
var
  tl: TTimeline;
  i: Integer;
begin
  Result := nil;
  if FProject = nil then Exit;
  tl := FProject.Timeline;
  { every channel is checked in turn: selected -> included (applied), not
    selected -> skipped }
  for i := 0 to tl.TrackCount - 1 do
    if (tl.GetTrack(i).Id = FTlSelectedTrackId) or
       (TlExtraTrackIndex(tl.GetTrack(i).Id) >= 0) then
      Result := Result + [tl.GetTrack(i).Id];
end;

procedure TfrmMain.TlExtraTrackRemove(AId: Integer);
var i: Integer;
begin
  i := TlExtraTrackIndex(AId);
  if i < 0 then Exit;
  Delete(FTlExtraTrackIds, i, 1);
end;

function TfrmMain.TlTrackAtY(AY: Integer; out ATrackIndex: Integer): Boolean;
var
  i, top: Integer;
begin
  ATrackIndex := -1;
  if AY < FTlView.RulerHeight then Exit(False);
  for i := 0 to FProject.Timeline.TrackCount - 1 do
  begin
    top := TlTrackTop(i);
    if (AY >= top) and (AY < top + FProject.Timeline.GetTrack(i).Height) then
    begin
      ATrackIndex := i;
      Exit(True);
    end;
  end;
  Result := False;
end;

function TfrmMain.TlClipAtPoint(AX, AY: Integer): TTimelineClip;
var
  ti, j: Integer;
  trk: TTimelineTrack;
  c: TTimelineClip;
  x1, x2: Double;
begin
  Result := nil;
  if (FProject = nil) or not TlTrackAtY(AY, ti) then Exit;
  trk := FProject.Timeline.GetTrack(ti);
  for j := 0 to trk.ClipCount - 1 do
  begin
    c := trk.GetClip(j);
    x1 := FTlView.SecondsToX(c.StartSeconds);
    x2 := FTlView.SecondsToX(c.EndSeconds);
    if (AX >= x1) and (AX <= x2) then
      Exit(c);
  end;
end;

function TfrmMain.TlFirstAudioTrackId: Integer;
var
  i: Integer;
  tl: TTimeline;
begin
  Result := -1;
  tl := FProject.Timeline;
  for i := 0 to tl.TrackCount - 1 do
    if tl.GetTrack(i).Kind = tkAudio then
      Exit(tl.GetTrack(i).Id);
end;

{ The selected Timeline lane is the Browser's explicit destination.  Keep it
  separate from FTlCtxTrackId: context menus are transient, while clicking a
  lane deliberately selects it for subsequent Browser adds. }
function TfrmMain.TlSelectedAudioTrackId: Integer;
var
  trk: TTimelineTrack;
begin
  Result := -1;
  if FProject = nil then Exit;
  trk := FProject.Timeline.TrackById(FTlSelectedTrackId);
  if (trk <> nil) and (trk.Kind = tkAudio) then
    Result := trk.Id;
end;

{ Every "Import to Timeline" entry point (WAV/MP3/MP4/Suno) calls this instead
  of reusing the first audio track, so each import lands on its own new
  "Audio N" track (N = existing audio-track count + 1). }
function TfrmMain.TlNewVideoTrackId: Integer;
var
  i, count: Integer;
  tl: TTimeline;
  addTrack: TAddTimelineTrackCommand;
begin
  tl := FProject.Timeline;
  count := 0;
  for i := 0 to tl.TrackCount - 1 do
    if tl.GetTrack(i).Kind = tkVideo then
      Inc(count);
  addTrack := TAddTimelineTrackCommand.Create(FProject, tkVideo, Format('Video %d', [count + 1]));
  FCmds.Perform(addTrack);
  Result := addTrack.CreatedId;
end;

function TfrmMain.TlNewAudioTrackId: Integer;
var
  i, count: Integer;
  tl: TTimeline;
  addTrack: TAddTimelineTrackCommand;
begin
  tl := FProject.Timeline;
  count := 0;
  for i := 0 to tl.TrackCount - 1 do
    if tl.GetTrack(i).Kind = tkAudio then
      Inc(count);
  addTrack := TAddTimelineTrackCommand.Create(FProject, tkAudio, Format('Audio %d', [count + 1]));
  FCmds.Perform(addTrack);
  Result := addTrack.CreatedId;
end;

function TfrmMain.TlTrackIndexById(ATrackId: Integer): Integer;
var
  i: Integer;
  tl: TTimeline;
begin
  Result := -1;
  if FProject = nil then Exit;
  tl := FProject.Timeline;
  for i := 0 to tl.TrackCount - 1 do
    if tl.GetTrack(i).Id = ATrackId then
      Exit(i);
end;

{ Shared destination rule for both external (Explorer, WMDropFiles) and
  in-app (Browser tree, pbTimelineDragDrop) file drops: land on the audio
  track under the drop point when there is one, otherwise fall back to
  whatever track is already selected in the Timeline (the "selected header"),
  and only create a brand new audio track when neither applies - a drop
  should never silently fail to find a place to land. }
function TfrmMain.TlDropTargetTrackId(AX, AY: Integer): Integer;
var
  ti: Integer;
begin
  if TlTrackAtY(AY, ti) and (FProject.Timeline.GetTrack(ti).Kind = tkAudio) then
    Result := FProject.Timeline.GetTrack(ti).Id
  else if TlSelectedAudioTrackId >= 0 then
    Result := TlSelectedAudioTrackId
  else
    Result := TlNewAudioTrackId;
end;

{ Bottom status-bar progress reporting for long-running operations (media
  import, tracker-module-to-audio bounce). prgStatus overlays the right end
  of stbMain (anchored bottom/right in the .dfm/.lfm so it tracks the bar
  across resizes); ProcessMessages keeps the UI paint pump alive across the
  synchronous work these imports do without pulling in a worker thread. }
procedure TfrmMain.FxBegin(const AName: string; AItems, AStagesPerItem: Integer; ALog: TMemo);
begin
  FFxName := AName;
  FFxItems := AItems;
  FFxPer := AStagesPerItem;
  FFxItem := 0;
  FFxDone := 0;
  FFxTotal := AItems * AStagesPerItem;
  FFxLog := ALog;
  ShowStatusProgress(AName + ' - starting...', Max(1, FFxTotal) * 100);
  if FFxLog <> nil then
    FFxLog.Lines.Insert(0, Format('%s: %d item(s) x %d stage(s) = %d stages total',
      [AName, AItems, AStagesPerItem, FFxTotal]));
  Application.ProcessMessages;
end;

procedure TfrmMain.FxItem(ANo: Integer);
begin
  FFxItem := ANo;
  FFxDone := (ANo - 1) * FFxPer;   // self-corrects if an earlier item bailed out early
end;

procedure TfrmMain.FxStage(AStageNo: Integer; const AWhat: string; APct: Integer);
begin
  UpdateStatusProgress(FFxDone * 100 + APct,
    Format('%s - item %d/%d - stage %d/%d: %s (%d%%)  [overall %d/%d stages]',
      [FFxName, FFxItem, FFxItems, AStageNo, FFxPer, AWhat, APct, FFxDone, FFxTotal]));
end;

procedure TfrmMain.FxStageDone(AStageNo: Integer; const AWhat: string);
begin
  Inc(FFxDone);
  FxStage(AStageNo, AWhat + ' done', 100);
  if FFxLog <> nil then
    FFxLog.Lines.Insert(0, Format('  %s  item %d/%d  stage %d/%d  %s - done',
      [FFxName, FFxItem, FFxItems, AStageNo, FFxPer, AWhat]));
  Application.ProcessMessages;
end;

procedure TfrmMain.FxEnd;
begin
  HideStatusProgress;
  FFxLog := nil;
end;

procedure TfrmMain.ShowStatusProgress(const AText: string; AMax: Integer);
begin
  if AMax < 1 then AMax := 1;
  FSyncProgressActive := True;
  prgStatus.Style := pbstNormal;
  prgStatus.Min := 0;
  prgStatus.Max := AMax;
  prgStatus.Position := 0;
  prgStatus.Visible := True;
  stbMain.SimpleText := AText;
  stbMain.Update;
  prgStatus.Update;
end;

{ For work with no meaningful percentage (waiting on a network reply from an
  AI provider) - a marquee bar still tells the user something is happening
  instead of the UI looking frozen, which ShowStatusProgress's determinate
  bar can't do until there's a real fraction to report. Callers switch back
  to ShowStatusProgress once they have one (e.g. applying N parsed AI tool
  calls one at a time). }
procedure TfrmMain.ShowStatusBusy(const AText: string);
begin
  FSyncProgressActive := True;
  prgStatus.Style := pbstMarquee;
  prgStatus.MarqueeInterval := 30;
  prgStatus.Visible := True;
  stbMain.SimpleText := AText;
  stbMain.Update;
  prgStatus.Update;
end;

procedure TfrmMain.UpdateStatusProgress(AValue: Integer; const AText: string);
begin
  if AText <> '' then stbMain.SimpleText := AText;
  if AValue < prgStatus.Min then AValue := prgStatus.Min;
  if AValue > prgStatus.Max then AValue := prgStatus.Max;
  prgStatus.Position := AValue;
  stbMain.Update;
  prgStatus.Update;
end;

procedure TfrmMain.HideStatusProgress;
begin
  prgStatus.Style := pbstNormal;
  prgStatus.Visible := False;
  prgStatus.Position := 0;
  FSyncProgressActive := False;
end;

{ ---- Registration (Settings > Registration) ----
  Unregistered UDAW runs with full functionality except exporting of any kind
  and any use of AI - every export and AI entry point calls RequireRegistration
  first. Registration itself is online (UDAW.Licensing -> system-verify.php,
  product 18); the executable-checksum + update check is UDAW.Update. }

function TfrmMain.RequireRegistration(const AFeature: string): Boolean;
begin
  {$IFDEF FPC}
  Result := True;   // Windows-only licensing for now; the FPC leg is unrun
  {$ELSE}
  Result := TUDAWLicense.IsRegistered;
  if Result then Exit;
  pgc.ActivePage := tabSettings;
  pgcSettings.ActivePage := tabRegistration;
  pgcChange(pgc);
  MessageDlg(AFeature + ' is not available in the unregistered version of UDAW.' +
    sLineBreak + sLineBreak +
    'Enter the username, password and serial number key from your ultimanium.com ' +
    'account on this Registration tab to unlock exporting and AI.',
    mtInformation, [mbOK], 0);
  {$ENDIF}
end;

procedure TfrmMain.UpdateRegistrationUI;
{$IFNDEF FPC}
var
  user, baseCaption: string;
  secs: Integer;
begin
  baseCaption := Format('UDAW - by Ultimanium Designs (C) 2026 - %s', [UDAWDisplayVersionString]);
  lblRegStatus.Caption := TUDAWLicense.CurrentEdition;
  if TUDAWLicense.IsRegistered then
  begin
    user := TUDAWLicense.RegisteredUsername;
    if user = '' then user := TUDAWLicense.CachedUsername;
    lblRegStatus.Font.Color := clGreen;
    lblRegDetail.Caption := Format('Registered to %s. %s', [user, TUDAWLicense.LastMessage]);
    Caption := baseCaption + ' - Registered to ' + user;
    secs := TUDAWLicense.OfflineSecondsRemaining;
    if secs >= 0 then
    begin
      lblRegStatus.Font.Color := clMaroon;
      lblRegDetail.Caption := lblRegDetail.Caption + Format(
        #13#10'CONNECTION LOST - UDAW will shut down in %.2d:%.2d:%.2d unless the licence server ' +
        'is reached again. Reconnecting cancels the countdown.',
        [secs div 3600, (secs mod 3600) div 60, secs mod 60]);
      Caption := Caption + Format(' - OFFLINE, shutdown in %.2d:%.2d:%.2d',
        [secs div 3600, (secs mod 3600) div 60, secs mod 60]);
    end;
    // The serial is never shown or copyable while registered.
    edtRegSerial.Text := StringOfChar('*', 20);
    edtRegSerial.PasswordChar := '*';
    edtRegSerial.Enabled := False;
  end
  else
  begin
    if not edtRegSerial.Enabled then
    begin
      edtRegSerial.Enabled := True;
      edtRegSerial.Text := TUDAWLicense.CachedSerial;
    end;
    lblRegStatus.Font.Color := clMaroon;
    lblRegDetail.Caption := Trim(TUDAWLicense.LastMessage + ' Exporting and AI are disabled.');
    Caption := baseCaption + ' - UNREGISTERED';
  end;
  btnRegUnregister.Enabled := TUDAWLicense.IsRegistered or TUDAWLicense.HasCachedCredentials;
  btnRegRegister.Enabled := not TUDAWLicense.IsRegistered;
end;
{$ELSE}
begin
end;
{$ENDIF}

procedure TfrmMain.btnRegRegisterClick(Sender: TObject);
{$IFNDEF FPC}
var
  u, p, sn: string;
begin
  u := Trim(edtRegUsername.Text);
  p := edtRegPassword.Text;
  sn := Trim(edtRegSerial.Text);
  if (u = '') or (p = '') or (sn = '') then
  begin
    MessageDlg('Enter your username, password and serial number key.', mtInformation, [mbOK], 0);
    Exit;
  end;
  btnRegRegister.Enabled := False;
  ShowStatusBusy('Contacting the registration server...');
  TUDAWLicense.VerifyAsync(u, p, sn,
    procedure(R: TLicenseResult)
    begin
      HideStatusProgress;
      btnRegRegister.Enabled := not TUDAWLicense.IsRegistered;
      case R.Status of
        lsOK:
          begin
            edtRegPassword.Text := '';
            TUDAWLicense.StartHeartbeat;
            MessageDlg('UDAW is now registered. Exporting and AI are unlocked.',
              mtInformation, [mbOK], 0);
          end;
        lsOffline:
          MessageDlg('Could not reach the registration server. Check your internet ' +
            'connection and try again.' + sLineBreak + sLineBreak + R.Message,
            mtWarning, [mbOK], 0);
        lsBlocked:
          MessageDlg(R.Message, mtError, [mbOK], 0);
      else
        if (R.Message = '') or SameText(R.Message, 'DENIED') then
          MessageDlg('The username, password or serial number key was not accepted.',
            mtError, [mbOK], 0)
        else
          MessageDlg(R.Message, mtError, [mbOK], 0);
      end;
    end);
end;
{$ELSE}
begin
end;
{$ENDIF}

procedure TfrmMain.btnRegUnregisterClick(Sender: TObject);
begin
  {$IFNDEF FPC}
  if MessageDlg('Unregister UDAW on this computer? Exporting and AI will be ' +
    'disabled until you register again.', mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  TUDAWLicense.Unregister;
  edtRegPassword.Text := '';
  {$ENDIF}
end;

procedure TfrmMain.btnRegCheckUpdateClick(Sender: TObject);
begin
  {$IFNDEF FPC}
  btnRegCheckUpdate.Enabled := False;
  btnRegInstallUpdate.Enabled := False;
  lblRegUpdateStatus.Caption := 'Checking for updates...';
  ShowStatusBusy('Checking for updates...');
  TThread.CreateAnonymousThread(
    procedure
    var
      info: TUDAWUpdateInfo;
      err: string;
      ok: Boolean;
    begin
      ok := UDAWCheckForUpdate(info, err);
      TThread.Queue(nil,
        procedure
        begin
          HideStatusProgress;
          btnRegCheckUpdate.Enabled := True;
          if not ok then
            lblRegUpdateStatus.Caption := err
          else if info.UpdateAvailable then
          begin
            lblRegUpdateStatus.Caption := Format('Version %s is available (you have %s).',
              [info.ServerVersion, info.CurrentVersion]);
            if UDAWUpdaterPresent then
              btnRegInstallUpdate.Enabled := True
            else
              lblRegUpdateStatus.Caption := lblRegUpdateStatus.Caption +
                ' UDAWUpdater.exe is missing next to UDAW.exe, so it cannot be installed automatically.';
          end
          else if info.ExeMismatch then
            lblRegUpdateStatus.Caption :=
              'Warning: this executable does not match the published build of the same version.'
          else
            lblRegUpdateStatus.Caption := Format('UDAW is up to date (%s).', [info.CurrentVersion]);
          UpdateRegistrationUI;   // an executable mismatch also drops to unregistered
        end);
    end).Start;
  {$ENDIF}
end;

procedure TfrmMain.btnRegInstallUpdateClick(Sender: TObject);
begin
  {$IFNDEF FPC}
  if (FProject <> nil) and FProject.Dirty then
  begin
    MessageDlg('The project has unsaved changes. Save the project first - UDAW ' +
      'closes and restarts to install the update.', mtInformation, [mbOK], 0);
    Exit;
  end;
  if MessageDlg('Download and install the update now? UDAW will close and restart.',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  btnRegCheckUpdate.Enabled := False;
  btnRegInstallUpdate.Enabled := False;
  ShowStatusProgress('Downloading the update...', 100);
  TThread.CreateAnonymousThread(
    procedure
    var
      err: string;
      ok: Boolean;
    begin
      ok := UDAWApplyUpdate(err,
        procedure(const ADetail: string; APosition, ATotal: Integer)
        begin
          if ATotal = 100 then UpdateStatusProgress(APosition, ADetail)
          else stbMain.SimpleText := ADetail;
        end);
      TThread.Queue(nil,
        procedure
        begin
          if ok then
          begin
            // UDAWUpdater.exe is waiting for this process to release UDAW.exe.
            stbMain.SimpleText := 'Restarting to complete the update...';
            Application.Terminate;
          end
          else
          begin
            HideStatusProgress;
            btnRegCheckUpdate.Enabled := True;
            btnRegInstallUpdate.Enabled := True;
            lblRegUpdateStatus.Caption := err;
          end;
        end);
    end).Start;
  {$ENDIF}
end;

{ ---- Import to Timeline (Timeline tab main menu + popup menu) ---- }

{ WAV/PCM - full-length import (unlike btnTlAddClipClick's 60s demo-clip
  cap), mirroring the MP3/MP4 undoable-clip import shape as closely as WAV's
  simpler AddSource/AddClip path allows. }
procedure TfrmMain.mnuTlImportWavClick(Sender: TObject);
var
  info: TWavInfo;
  tl: TTimeline;
  src: TMediaSource;
  trackId: Integer;
  addCmd: TAddTimelineClipCommand;
begin
  if FProject = nil then Exit;
  if not dlgOpenWav.Execute then Exit;
  ShowStatusProgress('Importing ' + ExtractFileName(dlgOpenWav.FileName) + '...', 100);
  try
    if not FileLooksLikeWav(dlgOpenWav.FileName) then
    begin
      memTimeline.Lines.Insert(0, 'not a WAV file: ' + dlgOpenWav.FileName);
      Exit;
    end;
    UpdateStatusProgress(10, 'Reading ' + ExtractFileName(dlgOpenWav.FileName) + '...');
    info := ReadWavInfo(dlgOpenWav.FileName);
    tl := FProject.Timeline;
    trackId := TlNewAudioTrackId;
    src := tl.AddSource(dlgOpenWav.FileName, info.SampleRate, info.Channels, info.FrameCount);
    addCmd := TAddTimelineClipCommand.Create(FProject, trackId, src.Id,
      ExtractFileName(dlgOpenWav.FileName), FTlView.Snap(tl.PlayheadSeconds), 0,
      info.FrameCount / info.SampleRate);
    FCmds.Perform(addCmd);
    FTlSelClipId := addCmd.CreatedId;
    UpdateStatusProgress(30, 'Building waveform for ' + ExtractFileName(dlgOpenWav.FileName) + '...');
    WarmClipWaveform(src.Id, 30, 70, False);
    UpdateStatusProgress(100, 'Import complete: ' + ExtractFileName(dlgOpenWav.FileName));
    Logger.Info('ui', 'WAV imported to timeline: ' + dlgOpenWav.FileName);
    ApplyBaselineTempoOnImport(addCmd.CreatedId);
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'WAV import FAILED: ' + E.Message);
  end;
  HideStatusProgress;
end;

{ Import the selected FLAC onto the timeline as an undoable non-destructive
  clip (TImportFlacCommand), mirroring the MP3/MP4 add-clip path. }
procedure TfrmMain.mnuTlImportFlacClick(Sender: TObject);
var
  tl: TTimeline;
  trackId: Integer;
  cmd: TImportFlacCommand;
begin
  if FProject = nil then Exit;
  if not dlgOpenFlac.Execute then Exit;
  ShowStatusProgress('Importing ' + ExtractFileName(dlgOpenFlac.FileName) + '...', 100);
  try
    if not FlacSniffFile(dlgOpenFlac.FileName) then
    begin
      memTimeline.Lines.Insert(0, 'not a FLAC file: ' + dlgOpenFlac.FileName);
      Exit;
    end;
    UpdateStatusProgress(10, 'Reading ' + ExtractFileName(dlgOpenFlac.FileName) + '...');
    tl := FProject.Timeline;
    trackId := TlNewAudioTrackId;

    cmd := TImportFlacCommand.Create(FProject, trackId, dlgOpenFlac.FileName,
      FTlView.Snap(tl.PlayheadSeconds), 0);
    FCmds.Perform(cmd);
    UpdateStatusProgress(30, 'Building waveform for ' + ExtractFileName(dlgOpenFlac.FileName) + '...');
    WarmClipWaveform(cmd.SourceId, 30, 70, False);
    UpdateStatusProgress(100, 'Import complete: ' + ExtractFileName(dlgOpenFlac.FileName));
    memTimeline.Lines.Insert(0, Format(
      'imported onto timeline: %s  (%d Hz, %d ch, %.3f s, clip id %d)',
      [dlgOpenFlac.FileName, cmd.ImportedSampleRate, cmd.ImportedChannels,
       cmd.ImportedLengthSeconds, cmd.CreatedClipId]));
    Logger.Info('ui', 'FLAC imported to timeline: ' + dlgOpenFlac.FileName);
    ApplyBaselineTempoOnImport(cmd.CreatedClipId);
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'FLAC import FAILED: ' + E.Message);
  end;
  HideStatusProgress;
end;

{ Tracker modules don't sit on the timeline as authored - the module is
  rendered once (song played through in full, LoopSong off) into PCM via
  TTrackerPlayer.RenderSongToPlanar, bounced to a WAV file under the cache
  folder, then imported exactly like any other WAV file. The rendered WAV
  (not the original module) becomes the clip's backing TMediaSource, since
  the timeline only knows how to reference file-based sources. }
procedure TfrmMain.TrkImportRenderProgress(Sender: TObject; AFraction: Double);
begin
  UpdateStatusProgress(Round(AFraction * 100));
end;

{ Tracker channels sum at unity gain with no per-voice headroom reduction,
  so a dense pattern's true peak routinely lands above 1.0 - scales the
  whole render down to sit just under full scale when that happens, which
  keeps the bounce's relative levels/dynamics intact (unlike hard-clamping,
  which would audibly distort it). A peak at or under 1.0 is left untouched. }
procedure TfrmMain.NormalizeTrackerRender(var APlanar: TAudioPlanar; AFrameCount: Integer);
const
  TARGET_PEAK = 0.999;
var
  ch, i: Integer;
  peak, v, scale: Single;
begin
  peak := 0;
  for ch := 0 to Length(APlanar) - 1 do
    for i := 0 to AFrameCount - 1 do
    begin
      v := Abs(APlanar[ch][i]);
      if v > peak then peak := v;
    end;
  if peak <= TARGET_PEAK then Exit;

  scale := TARGET_PEAK / peak;
  for ch := 0 to Length(APlanar) - 1 do
    for i := 0 to AFrameCount - 1 do
      APlanar[ch][i] := APlanar[ch][i] * scale;
end;

{ Builds a just-imported source's waveform peak cache right away and logs any
  failure to memTimeline immediately, instead of leaving it to the lazy
  build-on-first-paint in pbTimelinePaint (still there as a fallback for
  clips from an older project reload). WAV rarely fails this; MP3/MP4 decode
  a real compressed bitstream and can fail in file-specific ways WAV never
  does, so surfacing that at import time - the same way for every format -
  is what makes "clip shows no waveform" diagnosable instead of a silent,
  format-inconsistent mystery. }
procedure TfrmMain.WarmClipWaveform(ASourceId: Integer; AProgressBase,
  AProgressSpan: Integer; AShowProgress: Boolean);
var
  src: TMediaSource;
  progress: TMediaProgressScope;
  lastValue: Integer;
begin
  if (FProject = nil) or (ASourceId < 0) then Exit;
  src := FProject.Timeline.SourceById(ASourceId);
  if (src = nil) or (src.Waveform <> nil) or (src.Kind = mkVideoFile) then Exit;
  if AShowProgress then
    ShowStatusProgress('Building waveform for ' + ExtractFileName(src.Path) + '...', 100);
  lastValue := AProgressBase;
  progress := TMediaProgressScope.Create(
    procedure(Fraction: Double; const Detail: string)
    var value: Integer;
    begin
      if Pos('Building waveform', Detail) = 1 then
        value := AProgressBase + Round((0.85 + Fraction * 0.15) * AProgressSpan)
      else
        value := AProgressBase + Round(Fraction * 0.85 * AProgressSpan);
      lastValue := Max(lastValue, value);
      UpdateStatusProgress(lastValue, ExtractFileName(src.Path) + ' | ' + Detail);
    end);
  try
  try
    src.EnsureWaveform(
      procedure(AFraction: Double)
      begin
        if (AFraction > 0) and (AFraction < 1) then Exit;
        lastValue := Max(lastValue, AProgressBase + Round(AFraction * AProgressSpan));
        UpdateStatusProgress(lastValue,
          Format('Building waveform for %s (%d%%)...',
            [ExtractFileName(src.Path), Round(AFraction * 100)]));
      end);
  except
    on E: Exception do
    begin
      if FTlWaveformWarned.IndexOf(IntToStr(src.Id)) < 0 then
      begin
        FTlWaveformWarned.Add(IntToStr(src.Id));
        memTimeline.Lines.Insert(0, Format(
          'waveform unavailable for "%s": %s', [ExtractFileName(src.Path), E.Message]));
      end;
      Logger.Warn('ui', 'waveform build failed: ' + E.Message);
    end;
  end;
  finally
    progress.Free;
    if AShowProgress then HideStatusProgress;
  end;
end;

procedure TfrmMain.ImportTrackerModuleToTimeline(AModule: TTrackerModule;
  const ASourceFileName, AKindLabel: string);
const
  MAX_RENDER_MINUTES = 20;
var
  player: TTrackerPlayer;
  planar: TAudioPlanar;
  maxFrames, sampleRate, channels: Integer;
  renderPath, renderDir: string;
  tl: TTimeline;
  src: TMediaSource;
  trackId: Integer;
  addCmd: TAddTimelineClipCommand;
  frameCount: Integer;
begin
  sampleRate := FProject.SampleRate;
  channels := FProject.Channels;
  if channels < 1 then channels := 2;
  maxFrames := sampleRate * 60 * MAX_RENDER_MINUTES;

  ShowStatusProgress('Rendering ' + AKindLabel + ' "' + ASourceFileName + '" to audio...', 100);
  player := TTrackerPlayer.Create(AModule);
  try
    { RenderSongToPlanar reuses whatever sample rate the player is already
      prepared at, so pin it to the project's rate (not the player's
      UDAW_DEFAULT_SAMPLE_RATE construction default) before rendering. }
    player.Prepare(sampleRate, 1024, channels);
    try
      planar := player.RenderSongToPlanar(maxFrames, channels, 1024, TrkImportRenderProgress);
    except
      on E: Exception do
      begin
        memTimeline.Lines.Insert(0, AKindLabel + ' render FAILED: ' + E.Message);
        Exit;
      end;
    end;

    frameCount := 0;
    if Length(planar) > 0 then frameCount := Length(planar[0]);
    if frameCount < 1 then
    begin
      memTimeline.Lines.Insert(0, AKindLabel + ' rendered no audio: ' + ASourceFileName);
      Exit;
    end;

    { Tracker channels are summed at unity gain with no per-voice headroom
      reduction, so a dense pattern routinely bounces to peaks well above
      1.0 - saved as-is (SaveWavFile below writes float32, unclamped) that
      is real out-of-range sample data, not a display bug: the waveform
      peak cache draws exactly what's in the file, so it painted outside
      the clip rectangle into neighbouring lanes. Scale the whole render
      down to just under full scale rather than hard-clamping, so the bounce
      keeps its dynamics/relative levels intact instead of clipping. }
    NormalizeTrackerRender(planar, frameCount);

    UpdateStatusProgress(100, 'Writing rendered audio...');
    renderDir := IncludeTrailingPathDelimiter(CacheFile('render'));
    ForceDirectories(renderDir);
    renderPath := renderDir + ChangeFileExt(ExtractFileName(ASourceFileName), '') +
      Format('-%d.wav', [DateTimeToFileDate(Now)]);
    SaveWavFile(renderPath, planar, channels, sampleRate, frameCount);

    tl := FProject.Timeline;
    trackId := TlNewAudioTrackId;
    src := tl.AddSource(renderPath, sampleRate, channels, frameCount);
    addCmd := TAddTimelineClipCommand.Create(FProject, trackId, src.Id,
      ExtractFileName(ASourceFileName) + ' (rendered)',
      FTlView.Snap(tl.PlayheadSeconds), 0, frameCount / sampleRate);
    FCmds.Perform(addCmd);
    WarmClipWaveform(src.Id);
    FTlSelClipId := addCmd.CreatedId;
    Logger.Info('ui', AKindLabel + ' rendered to timeline: ' + ASourceFileName);
    RefreshTimelineTab;
  finally
    player.Free;
    HideStatusProgress;
  end;
end;

procedure TfrmMain.mnuTlImportModClick(Sender: TObject);
var
  fs: TFileStream;
  data: TBytes;
  info: TModImportInfo;
  module: TTrackerModule;
begin
  if FProject = nil then Exit;
  if not dlgOpenMod.Execute then Exit;
  if not FileLooksLikeMod(dlgOpenMod.FileName) then
  begin
    MessageDlg('That file is not a recognisable ProTracker / Soundtracker MOD:'
      + sLineBreak + dlgOpenMod.FileName, mtWarning, [mbOK], 0);
    Exit;
  end;
  try
    fs := TFileStream.Create(dlgOpenMod.FileName, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(data, fs.Size);
      if Length(data) > 0 then fs.ReadBuffer(data[0], Length(data));
    finally
      fs.Free;
    end;
    module := ModToModule(data, info);
    try
      ImportTrackerModuleToTimeline(module, dlgOpenMod.FileName, 'MOD');
    finally
      module.Free;
    end;
  except
    on E: Exception do
      MessageDlg('MOD import to timeline FAILED:' + sLineBreak + E.Message, mtError, [mbOK], 0);
  end;
end;

procedure TfrmMain.mnuTlImportXmClick(Sender: TObject);
var
  fs: TFileStream;
  data: TBytes;
  info: TXmImportInfo;
  module: TTrackerModule;
begin
  if FProject = nil then Exit;
  if not dlgOpenXm.Execute then Exit;
  if not FileLooksLikeXm(dlgOpenXm.FileName) then
  begin
    MessageDlg('That file is not a recognisable FastTracker 2 Extended Module:'
      + sLineBreak + dlgOpenXm.FileName, mtWarning, [mbOK], 0);
    Exit;
  end;
  try
    fs := TFileStream.Create(dlgOpenXm.FileName, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(data, fs.Size);
      if Length(data) > 0 then fs.ReadBuffer(data[0], Length(data));
    finally
      fs.Free;
    end;
    module := XmToModule(data, info);
    try
      ImportTrackerModuleToTimeline(module, dlgOpenXm.FileName, 'XM');
    finally
      module.Free;
    end;
  except
    on E: Exception do
      MessageDlg('XM import to timeline FAILED:' + sLineBreak + E.Message, mtError, [mbOK], 0);
  end;
end;

procedure TfrmMain.mnuTlImportMptmClick(Sender: TObject);
var
  fs: TFileStream;
  data: TBytes;
  info: TMPTMImportInfo;
  module: TTrackerModule;
begin
  if FProject = nil then Exit;
  if not dlgOpenMptm.Execute then Exit;
  if not FileLooksLikeMptm(dlgOpenMptm.FileName) then
  begin
    MessageDlg('That file is not a recognisable IMPM (IT / MPTM) module:'
      + sLineBreak + dlgOpenMptm.FileName, mtWarning, [mbOK], 0);
    Exit;
  end;
  try
    fs := TFileStream.Create(dlgOpenMptm.FileName, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(data, fs.Size);
      if Length(data) > 0 then fs.ReadBuffer(data[0], Length(data));
    finally
      fs.Free;
    end;
    module := MptmToModule(data, info);
    try
      ImportTrackerModuleToTimeline(module, dlgOpenMptm.FileName, 'IT/MPTM');
    finally
      module.Free;
    end;
  except
    on E: Exception do
      MessageDlg('IT/MPTM import to timeline FAILED:' + sLineBreak + E.Message, mtError, [mbOK], 0);
  end;
end;

{ Import a whole Ableton Live Set: one undo step (TImportAlsProjectCommand)
  that creates a new audio track per parsed AudioTrack and a clip per
  resolved AudioClip - unlike the single-clip Import*Command handlers above,
  this one doesn't need a target track id at all, since the command makes
  its own. Every AlsParseFile / per-clip warning (skipped MIDI tracks,
  unresolved samples, unimported automation/warp features, ...) is logged
  to memTimeline rather than silently dropped. }
procedure TfrmMain.mnuTlImportAlsClick(Sender: TObject);
var
  cmd: TImportAlsProjectCommand;
  i: Integer;
  warnings: TArray<string>;
begin
  if FProject = nil then Exit;
  if not dlgOpenAls.Execute then Exit;
  ShowStatusProgress('Importing ' + ExtractFileName(dlgOpenAls.FileName) + '...', 100);
  try
    if not AlsSniffFile(dlgOpenAls.FileName) then
    begin
      memTimeline.Lines.Insert(0, 'not a GZIP-compressed Ableton Live Set: ' + dlgOpenAls.FileName);
      Exit;
    end;
    UpdateStatusProgress(10, 'Reading ' + ExtractFileName(dlgOpenAls.FileName) + '...');
    cmd := TImportAlsProjectCommand.Create(FProject, dlgOpenAls.FileName,
      FTlView.Snap(FProject.Timeline.PlayheadSeconds));
    FCmds.Perform(cmd);
    UpdateStatusProgress(90, 'Building waveforms...');
    warnings := cmd.Warnings;
    memTimeline.Lines.Insert(0, Format(
      'imported Ableton project onto timeline: %s  (%.1f BPM, %d audio track(s), %d warning(s))',
      [dlgOpenAls.FileName, cmd.ImportedTempo, cmd.AudioTrackCount, Length(warnings)]));
    for i := High(warnings) downto 0 do
      memTimeline.Lines.Insert(0, '  ' + warnings[i]);
    UpdateStatusProgress(100, 'Import complete: ' + ExtractFileName(dlgOpenAls.FileName));
    Logger.Info('ui', 'Ableton Live Set imported to timeline: ' + dlgOpenAls.FileName);
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'Ableton Live Set import FAILED: ' + E.Message);
  end;
  HideStatusProgress;
end;

{ Import an FL Studio Playlist as one undoable timeline operation. The parser
  reports unsupported generator/MIDI/plugin data as warnings; audio clips
  backed by files UDAW can decode are the only entries made into timeline
  sources, so this never manufactures playable-looking but silent clips. }
procedure TfrmMain.mnuTlImportFlpClick(Sender: TObject);
var
  cmd: TImportFlpProjectCommand;
  i: Integer;
  warnings: TArray<string>;
begin
  if FProject = nil then Exit;
  if not dlgOpenFlp.Execute then Exit;
  ShowStatusProgress('Importing ' + ExtractFileName(dlgOpenFlp.FileName) + '...', 100);
  try
    if not FlpSniffFile(dlgOpenFlp.FileName) then
    begin
      memTimeline.Lines.Insert(0, 'not an FL Studio project: ' + dlgOpenFlp.FileName);
      Exit;
    end;
    UpdateStatusProgress(10, 'Reading ' + ExtractFileName(dlgOpenFlp.FileName) + '...');
    cmd := TImportFlpProjectCommand.Create(FProject, dlgOpenFlp.FileName,
      FTlView.Snap(FProject.Timeline.PlayheadSeconds));
    FCmds.Perform(cmd);
    UpdateStatusProgress(90, 'Building waveforms...');
    warnings := cmd.Warnings;
    memTimeline.Lines.Insert(0, Format(
      'imported FL Studio project onto timeline: %s  (%.1f BPM, %d audio track(s), %d clip(s), %d warning(s))',
      [dlgOpenFlp.FileName, cmd.ImportedTempo, cmd.ImportedTrackCount,
       cmd.ImportedClipCount, Length(warnings)]));
    for i := High(warnings) downto 0 do
      memTimeline.Lines.Insert(0, '  ' + warnings[i]);
    UpdateStatusProgress(100, 'Import complete: ' + ExtractFileName(dlgOpenFlp.FileName));
    Logger.Info('ui', 'FL Studio project imported to timeline: ' + dlgOpenFlp.FileName);
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'FL Studio project import FAILED: ' + E.Message);
  end;
  HideStatusProgress;
end;

{ ~6px hit zone on either edge of a clip, used to switch mouse-down from a
  whole-clip move into a TTrimTimelineClipCommand drag. }
function TfrmMain.TlHitTestClipEdge(AClip: TTimelineClip; AX: Integer;
  out AEdge: TClipEdge): Boolean;
const
  EDGE_PX = 6;
var
  x1, x2: Double;
begin
  x1 := FTlView.SecondsToX(AClip.StartSeconds);
  x2 := FTlView.SecondsToX(AClip.EndSeconds);
  if Abs(AX - x2) <= EDGE_PX then
  begin
    AEdge := ceEnd;
    Exit(True);
  end;
  if Abs(AX - x1) <= EDGE_PX then
  begin
    AEdge := ceStart;
    Exit(True);
  end;
  Result := False;
end;

{ FL-Studio-style fade handle: a small square grabbable at the top-left/
  top-right corner of a clip's body (see pbTimelinePaint's CLIP_HEADER_H),
  independent of - and checked before - the full-height trim-edge zone above,
  so the two never fight over the same pixels. Always live, even when the
  clip has no fade yet, so a drag from a flat corner starts one from zero. }
function TfrmMain.TlHitTestFadeHandle(AClip: TTimelineClip; ATrackIndex, AX, AY: Integer;
  out AEdge: TClipEdge): Boolean;
const
  CLIP_HEADER_H = 15;   { must match pbTimelinePaint's local constant }
  CORNER_PX = 9;
var
  top, bodyTop: Integer;
  x1, x2: Double;
begin
  Result := False;
  if ATrackIndex < 0 then Exit;
  top := TlTrackTop(ATrackIndex);
  bodyTop := top + 2 + CLIP_HEADER_H;
  if (AY < bodyTop) or (AY > bodyTop + CORNER_PX) then Exit;
  x1 := FTlView.SecondsToX(AClip.StartSeconds);
  x2 := FTlView.SecondsToX(AClip.EndSeconds);
  if (AX >= x1) and (AX <= x1 + CORNER_PX) then
  begin
    AEdge := ceStart;
    Exit(True);
  end;
  if (AX <= x2) and (AX >= x2 - CORNER_PX) then
  begin
    AEdge := ceEnd;
    Exit(True);
  end;
end;

function TfrmMain.TlIsClipSelected(AClipId: Integer): Boolean;
var
  i: Integer;
begin
  if AClipId = FTlSelClipId then Exit(True);
  for i := 0 to High(FTlSelClipIds) do
    if FTlSelClipIds[i] = AClipId then Exit(True);
  Result := False;
end;

function TfrmMain.TlTrackHasSelectedClip(ATrack: TTimelineTrack): Boolean;
var
  i: Integer;
begin
  for i := 0 to ATrack.ClipCount - 1 do
    if TlIsClipSelected(ATrack.GetClip(i).Id) then Exit(True);
  Result := False;
end;

procedure TfrmMain.TlSetSingleSelection(AClipId: Integer);
begin
  FTlSelClipId := AClipId;
  SetLength(FTlSelClipIds, 0);
end;

{ Ctrl/Shift-click: add or drop one clip from the multi-selection, keeping
  FTlSelClipId as the "primary" clip (drives memTimeline's details readout,
  Cut/Copy/Split/etc). The primary is never stored twice in FTlSelClipIds. }
procedure TfrmMain.TlToggleSelection(AClipId: Integer);
var
  i: Integer;
begin
  if AClipId = FTlSelClipId then
  begin
    { dropping the primary: promote the first extra selection if there is one }
    if Length(FTlSelClipIds) > 0 then
    begin
      FTlSelClipId := FTlSelClipIds[0];
      Delete(FTlSelClipIds, 0, 1);
    end
    else
      FTlSelClipId := -1;
    Exit;
  end;
  for i := 0 to High(FTlSelClipIds) do
    if FTlSelClipIds[i] = AClipId then
    begin
      Delete(FTlSelClipIds, i, 1);
      Exit;
    end;
  if FTlSelClipId < 0 then
    FTlSelClipId := AClipId
  else
  begin
    SetLength(FTlSelClipIds, Length(FTlSelClipIds) + 1);
    FTlSelClipIds[High(FTlSelClipIds)] := AClipId;
  end;
end;

{ Alt+drag-to-duplicate (pbTimelineMouseDown): clones every currently
  selected clip in place, through the same undoable TAddTimelineClipCommand
  path btnTlPasteClick already uses (copying the same fields it restores
  after the add - a bare add-clip command doesn't carry gain/fade/reverse/
  mute/colour), then re-points the selection at the new clips so the group
  move that follows in pbTimelineMouseMove drags the COPIES, leaving the
  originals untouched exactly where they were - the standard "hold a
  modifier and drag" duplicate gesture every arrangement view offers.
  Ctrl is already claimed by this timeline for multi-select add/toggle
  (see the `multi` flag above), so this uses Alt instead - unused anywhere
  else on the timeline. Returns the new clip ids in original-selection
  order, or an empty array if there was nothing selected or every selected
  clip had since vanished (caller falls back to a normal move in that case). }
function TfrmMain.TlDuplicateSelectedClips: TArray<Integer>;
var
  tl: TTimeline;
  srcIds: TArray<Integer>;
  i, n: Integer;
  orig: TTimelineClip;
  trk: TTimelineTrack;
  addCmd: TAddTimelineClipCommand;
  dup: TTimelineClip;
  origSourceId, origTrackId: Integer;
  origName: string;
  origStart, origOffset, origLen, origGain, origFadeIn, origFadeOut: Double;
  origFadeInShape, origFadeOutShape: TFadeShape;
  origReversed, origMuted: Boolean;
  origColor: TColor;
begin
  Result := nil;
  if FProject = nil then Exit;
  tl := FProject.Timeline;

  SetLength(srcIds, 0);
  if FTlSelClipId >= 0 then
  begin
    SetLength(srcIds, Length(srcIds) + 1);
    srcIds[High(srcIds)] := FTlSelClipId;
  end;
  for i := 0 to High(FTlSelClipIds) do
  begin
    SetLength(srcIds, Length(srcIds) + 1);
    srcIds[High(srcIds)] := FTlSelClipIds[i];
  end;
  if Length(srcIds) = 0 then Exit;

  SetLength(Result, Length(srcIds));
  n := 0;
  for i := 0 to High(srcIds) do
  begin
    orig := tl.ClipById(srcIds[i], trk);
    if orig = nil then Continue;   // vanished since selection - skip it

    origTrackId := trk.Id;
    origSourceId := orig.SourceId;
    origName := orig.Name;
    origStart := orig.StartSeconds;
    origOffset := orig.SourceOffsetSeconds;
    origLen := orig.LengthSeconds;
    origGain := orig.GainDb;
    origFadeIn := orig.FadeInSeconds;
    origFadeOut := orig.FadeOutSeconds;
    origFadeInShape := orig.FadeInShape;
    origFadeOutShape := orig.FadeOutShape;
    origReversed := orig.Reversed;
    origMuted := orig.Muted;
    origColor := orig.Color;

    addCmd := TAddTimelineClipCommand.Create(FProject, origTrackId, origSourceId,
      origName, origStart, origOffset, origLen);
    FCmds.Perform(addCmd);
    dup := tl.ClipById(addCmd.CreatedId);
    if dup <> nil then
    begin
      dup.GainDb := origGain;
      dup.FadeInSeconds := origFadeIn;
      dup.FadeOutSeconds := origFadeOut;
      dup.FadeInShape := origFadeInShape;
      dup.FadeOutShape := origFadeOutShape;
      dup.Reversed := origReversed;
      dup.Muted := origMuted;
      dup.Color := origColor;
    end;
    Result[n] := addCmd.CreatedId;
    Inc(n);
  end;
  SetLength(Result, n);
  if n = 0 then Exit;

  TlSetSingleSelection(Result[0]);
  SetLength(FTlSelClipIds, n - 1);
  for i := 1 to n - 1 do
    FTlSelClipIds[i - 1] := Result[i];
end;

{ Replaces the selection with every clip whose body intersects the rubber-band
  rectangle (FTlRubberStartX/Y .. FTlRubberX/Y), matching the drag-a-box-over-
  clips gesture every arrangement view (FL's Playlist included) supports. }
procedure TfrmMain.TlSelectRubberBand;
var
  ti, j: Integer;
  trk: TTimelineTrack;
  c: TTimelineClip;
  x1, x2: Double;
  top: Integer;
  rx1, rx2, ry1, ry2: Integer;
  first: Boolean;
begin
  if FProject = nil then Exit;
  rx1 := Min(FTlRubberStartX, FTlRubberX);
  rx2 := Max(FTlRubberStartX, FTlRubberX);
  ry1 := Min(FTlRubberStartY, FTlRubberY);
  ry2 := Max(FTlRubberStartY, FTlRubberY);
  FTlSelClipId := -1;
  SetLength(FTlSelClipIds, 0);
  first := True;
  for ti := 0 to FProject.Timeline.TrackCount - 1 do
  begin
    trk := FProject.Timeline.GetTrack(ti);
    top := TlTrackTop(ti);
    if (top + trk.Height < ry1) or (top > ry2) then Continue;
    for j := 0 to trk.ClipCount - 1 do
    begin
      c := trk.GetClip(j);
      x1 := FTlView.SecondsToX(c.StartSeconds);
      x2 := FTlView.SecondsToX(c.EndSeconds);
      if (x2 < rx1) or (x1 > rx2) then Continue;
      if first then
      begin
        FTlSelClipId := c.Id;
        first := False;
      end
      else
      begin
        SetLength(FTlSelClipIds, Length(FTlSelClipIds) + 1);
        FTlSelClipIds[High(FTlSelClipIds)] := c.Id;
      end;
    end;
  end;
end;

{ The scrollbar's own Max/Position cannot be trusted to stay in range on
  their own: TScrollBar only auto-clamps a drag to Max-PageSize+1 when
  PageSize is set, and this one (like sbTlHorz) deliberately leaves PageSize
  at 0 and drives paging through LargeChange instead - so nothing stops the
  native control's Position from reaching all the way up to Max, well past
  where content actually ends. sbTlHorz never showed this because
  FTlView.ScrollToSeconds clamps internally regardless of what the scrollbar
  asked for; FTlVScrollY has no such model-layer clamp, so both
  SyncTimelineScrollbar and sbTlVertChange must clamp explicitly against this
  same ceiling to avoid ever painting past the last track (the visible
  symptom was bad flicker from repeatedly snapping an out-of-range thumb
  back while dragging). }
function TfrmMain.TlMaxVScroll: Integer;
begin
  Result := Max(0, TlTracksContentHeight - Max(1, pbTimeline.Height - FTlView.RulerHeight));
end;

procedure TfrmMain.SyncTimelineScrollbar;
var
  contentH, visibleH, maxScrollY: Integer;
begin
  FTlScrollGuard := True;
  try
    sbTlHorz.Min := 0;
    sbTlHorz.Max := Max(1, Round(FTlView.ContentSeconds * 10));
    sbTlHorz.LargeChange := Max(1,
      Round((FTlView.VisibleEndSeconds - FTlView.VisibleStartSeconds) * 10));
    sbTlHorz.SmallChange := Max(1, sbTlHorz.LargeChange div 8);
    sbTlHorz.Position := Max(sbTlHorz.Min,
      Min(sbTlHorz.Max, Round(FTlView.ScrollSeconds * 10)));

    { vertical: scrolls the channel list under the ruler, which stays fixed
      at the top - see TlTrackTop/TlTracksContentHeight. }
    contentH := TlTracksContentHeight;
    visibleH := Max(1, pbTimeline.Height - FTlView.RulerHeight);
    maxScrollY := TlMaxVScroll;
    if FTlVScrollY > maxScrollY then FTlVScrollY := maxScrollY;
    if FTlVScrollY < 0 then FTlVScrollY := 0;
    sbTlVert.Min := 0;
    sbTlVert.Max := Max(1, contentH);
    sbTlVert.LargeChange := Max(1, visibleH);
    sbTlVert.SmallChange := Max(1, visibleH div 8);
    sbTlVert.Position := FTlVScrollY;
    sbTlVert.Visible := maxScrollY > 0;
  finally
    FTlScrollGuard := False;
  end;
end;

{ Menu item Enabled/Caption changes must never land on pmTimeline while it is
  actually on screen: TrackPopupMenu's modal loop still dispatches WM_TIMER,
  so tmrUI kept firing into the old single RefreshTimelineTab and mutating
  the live popup's items mid-display - Win32 doesn't repaint an open menu
  when its items change under it, which is what made it "not present
  properly" (stale/garbled item text). So this sync only ever runs from an
  infrequent full refresh and from pmTimeline's OnPopup, immediately before
  the menu is shown - never from a per-tick path. }
procedure TfrmMain.SyncTimelineMenuState;
var
  tl: TTimeline;
  sel: TTimelineClip;
  ctxTrack: TTimelineTrack;
  ctxIndex: Integer;
begin
  if FProject = nil then Exit;
  tl := FProject.Timeline;
  sel := nil;
  if FTlSelClipId >= 0 then
    sel := tl.ClipById(FTlSelClipId);

  mnuTlDeleteClip.Enabled := sel <> nil;
  pmTlDeleteClip.Enabled := sel <> nil;
  mnuTlRemoveTrack.Enabled := FTlCtxTrackId >= 0;
  pmTlRemoveTrack.Enabled := FTlCtxTrackId >= 0;
  mnuTlSplit.Enabled := (sel <> nil) and sel.ContainsSeconds(tl.PlayheadSeconds);
  pmTlSplit.Enabled := mnuTlSplit.Enabled;
  mnuTlAddClip.Enabled := True;
  pmTlAddClip.Enabled := True;
  mnuTlPlay.Enabled := not FTlPlaying;
  pmTlPlay.Enabled := not FTlPlaying;
  mnuTlStop.Enabled := FTlPlaying;
  pmTlStop.Enabled := FTlPlaying;

  { Cut/Copy act on the current selection; Paste needs a held clip. }
  mnuTlCut.Enabled := sel <> nil;
  pmTlCut.Enabled := sel <> nil;
  mnuTlCopy.Enabled := sel <> nil;
  pmTlCopy.Enabled := sel <> nil;
  mnuTlPaste.Enabled := FTlHaveClipboard;
  pmTlPaste.Enabled := FTlHaveClipboard;
  pmTlCopySelection.Enabled := FTlRangeActive;
  mnuTlSaveSelWav.Enabled := FTlRangeActive;
  mnuTlSaveSelPcm.Enabled := FTlRangeActive;
  mnuTlSaveSelFlac.Enabled := FTlRangeActive;
  pmTlSaveSelWav.Enabled := FTlRangeActive;
  pmTlSaveSelPcm.Enabled := FTlRangeActive;
  pmTlSaveSelFlac.Enabled := FTlRangeActive;
  pmTlPasteSelection.Enabled := FTlHaveSelectionClipboard;

  { Track reorder: only enabled when the context track can actually move. }
  ctxIndex := -1;
  if FTlCtxTrackId >= 0 then
    ctxIndex := tl.IndexOfTrack(FTlCtxTrackId);
  mnuTlTrackUp.Enabled := ctxIndex > 0;
  pmTlTrackUp.Enabled := mnuTlTrackUp.Enabled;
  mnuTlTrackDown.Enabled := (ctxIndex >= 0) and (ctxIndex < tl.TrackCount - 1);
  pmTlTrackDown.Enabled := mnuTlTrackDown.Enabled;

  ctxTrack := nil;
  if FTlCtxTrackId >= 0 then
    ctxTrack := tl.TrackById(FTlCtxTrackId);   // nil if the project was replaced under a stale id
  mnuTlMuteTrack.Enabled := ctxTrack <> nil;
  pmTlMuteTrack.Enabled := mnuTlMuteTrack.Enabled;
  if ctxTrack <> nil then
  begin
    mnuTlMuteTrack.Checked := ctxTrack.Muted;
    pmTlMuteTrack.Checked := mnuTlMuteTrack.Checked;
  end
  else
  begin
    mnuTlMuteTrack.Checked := False;
    pmTlMuteTrack.Checked := False;
  end;

  mnuTlLoopToggle.Checked := tl.LoopEnabled;
  pmTlLoopToggle.Checked := tl.LoopEnabled;
  pmTlrLoopEnabled.Checked := tl.LoopEnabled;

  mnuTlLoopToRange.Enabled := FTlRangeActive;
  pmTlLoopToRange.Enabled := FTlRangeActive;
  pmTlrLoopToRange.Enabled := FTlRangeActive;

  { Normalize / Reverse / Effects: all operate on the active ruler-drag time
    range (FTlRangeActive), same as Split/Delete/Fade Range above - so they
    stay disabled until a range is actually selected. }
  mnuTlNormalizeRange.Enabled := FTlRangeActive;
  pmTlNormalizeRange.Enabled := FTlRangeActive;
  mnuTlReverseRange.Enabled := FTlRangeActive;
  pmTlReverseRange.Enabled := FTlRangeActive;
  mnuTlEffects.Enabled := FTlRangeActive;
  pmTlEffects.Enabled := FTlRangeActive;

  mnuTlUndo.Enabled := FCmds.CanUndo;
  pmTlUndo.Enabled := FCmds.CanUndo;
  pmTlrUndo.Enabled := FCmds.CanUndo;
  mnuTlRedo.Enabled := FCmds.CanRedo;
  pmTlRedo.Enabled := FCmds.CanRedo;
  pmTlrRedo.Enabled := FCmds.CanRedo;
  if FCmds.CanUndo then
  begin
    mnuTlUndo.Caption := 'Undo: ' + FCmds.UndoDescription;
    pmTlUndo.Caption := mnuTlUndo.Caption;
    pmTlrUndo.Caption := mnuTlUndo.Caption;
  end
  else
  begin
    mnuTlUndo.Caption := 'Undo';
    pmTlUndo.Caption := 'Undo';
    pmTlrUndo.Caption := 'Undo';
  end;
  if FCmds.CanRedo then
  begin
    mnuTlRedo.Caption := 'Redo: ' + FCmds.RedoDescription;
    pmTlRedo.Caption := mnuTlRedo.Caption;
    pmTlrRedo.Caption := mnuTlRedo.Caption;
  end
  else
  begin
    mnuTlRedo.Caption := 'Redo';
    pmTlRedo.Caption := 'Redo';
    pmTlrRedo.Caption := 'Redo';
  end;

  pmTlrPlay.Enabled := not FTlPlaying;
  pmTlrStop.Enabled := FTlPlaying;
end;

{ Builds a flat, jump-to-any-entry history list under an "Undo/Redo History"
  submenu: every command still on FCmds' undo stack (closest first), a
  separator, then every command on the redo stack (closest first). Picking
  an entry N steps down undoes/redoes N+1 commands in one go - the same
  "click an older state in the list" convention as Photoshop's History
  panel. Called fresh on every popup (SyncTimelineMenuState/pmTimelinePopup),
  so it never lists a step that Undo/Redo have since expired. }
procedure TfrmMain.PopulateTimelineHistoryMenu(AParent: TMenuItem);
const
  MAX_HISTORY_ITEMS = 25;
var
  i, n: Integer;
  mi: TMenuItem;
begin
  AParent.Clear;

  n := Min(FCmds.UndoCount, MAX_HISTORY_ITEMS);
  if n = 0 then
  begin
    mi := TMenuItem.Create(Self);
    mi.Caption := '(nothing to undo)';
    mi.Enabled := False;
    AParent.Add(mi);
  end
  else
    for i := 0 to n - 1 do
    begin
      mi := TMenuItem.Create(Self);
      if i = 0 then
        mi.Caption := 'Undo: ' + FCmds.UndoDescriptionAt(i)
      else
        mi.Caption := Format('Undo %d steps to before: %s', [i + 1, FCmds.UndoDescriptionAt(i)]);
      mi.Tag := -(i + 1);
      mi.OnClick := TlHistoryItemClick;
      AParent.Add(mi);
    end;

  mi := TMenuItem.Create(Self);
  mi.Caption := '-';
  AParent.Add(mi);

  n := Min(FCmds.RedoCount, MAX_HISTORY_ITEMS);
  if n = 0 then
  begin
    mi := TMenuItem.Create(Self);
    mi.Caption := '(nothing to redo)';
    mi.Enabled := False;
    AParent.Add(mi);
  end
  else
    for i := 0 to n - 1 do
    begin
      mi := TMenuItem.Create(Self);
      if i = 0 then
        mi.Caption := 'Redo: ' + FCmds.RedoDescriptionAt(i)
      else
        mi.Caption := Format('Redo %d steps to after: %s', [i + 1, FCmds.RedoDescriptionAt(i)]);
      mi.Tag := i + 1;
      mi.OnClick := TlHistoryItemClick;
      AParent.Add(mi);
    end;
end;

procedure TfrmMain.TlHistoryItemClick(Sender: TObject);
var
  steps: Integer;
begin
  steps := TMenuItem(Sender).Tag;
  if steps < 0 then
    FCmds.UndoMultiple(-steps)
  else if steps > 0 then
    FCmds.RedoMultiple(steps);
  RefreshTimelineTab;
end;

procedure TfrmMain.pmTimelinePopup(Sender: TObject);
begin
  SyncTimelineMenuState;
  PopulateTimelineHistoryMenu(pmTlHistory);
end;

{ Ruler-only context menu (see pbTimelineMouseDown/MouseUp's FTlRulerCtxActive):
  right-clicking the ruler already moved the playhead to the clicked, snapped
  position, so every command here can just act on tl.PlayheadSeconds exactly
  like the toolbar buttons they're wired to (Set Loop Start/End Here reuse
  btnTlLoopStartClick/btnTlLoopEndClick directly - no separate "ruler click
  position" plumbing needed). }
procedure TfrmMain.pmTimelineRulerPopup(Sender: TObject);
begin
  SyncTimelineMenuState;
  PopulateTimelineHistoryMenu(pmTlrHistory);
  pmTlrSplitRange.Enabled := FTlRangeActive;
  pmTlrDeleteRange.Enabled := FTlRangeActive;
  pmTlrFadeInRange.Enabled := FTlRangeActive;
  pmTlrFadeOutRange.Enabled := FTlRangeActive;
end;

procedure TfrmMain.btnTlAddMarkerHereClick(Sender: TObject);
var
  tl: TTimeline;
  nm: string;
begin
  if FProject = nil then Exit;
  tl := FProject.Timeline;
  nm := InputBox('Add Marker', 'Marker name:', Format('Marker %d', [tl.MarkerCount + 1]));
  if Trim(nm) = '' then Exit;
  FCmds.Perform(TAddTimelineMarkerCommand.Create(FProject, nm, tl.PlayheadSeconds));
  RefreshTimelineTab;
end;

procedure TfrmMain.btnTlGoStartClick(Sender: TObject);
begin
  if FProject = nil then Exit;
  FProject.Timeline.PlayheadSeconds := 0;
  FRecInsertSeconds := 0;
  FTlView.ScrollToSeconds(0);
  RefreshTimelineTab;
end;

procedure TfrmMain.btnTlGoEndClick(Sender: TObject);
var
  tl: TTimeline;
  endSec: Double;
begin
  if FProject = nil then Exit;
  tl := FProject.Timeline;
  endSec := tl.TotalDurationSeconds;
  tl.PlayheadSeconds := endSec;
  FRecInsertSeconds := endSec;
  FTlView.EnsureVisible(endSec);
  RefreshTimelineTab;
end;

{ Fits the whole arrangement (plus a 5% margin so the last clip/marker isn't
  flush against the right edge) into the current lane width - a fresh,
  from-scratch zoom level, not a relative ZoomBy step like the toolbar's
  Zoom In/Out. A 0-length arrangement (nothing on the timeline yet) falls
  back to a 30-second view instead of dividing by zero / zooming to infinity. }
procedure TfrmMain.btnTlZoomFitClick(Sender: TObject);
var
  dur: Double;
begin
  if FProject = nil then Exit;
  dur := FProject.Timeline.TotalDurationSeconds;
  if dur <= 0 then dur := 30;
  FTlView.SetZoom(TlLaneWidth / (dur * 1.05));
  FTlView.ScrollToSeconds(0);
  RefreshTimelineTab;
end;

{ Fires on WM_INITMENUPOPUP for the top-level "Timeline" main-menu item,
  i.e. immediately before Windows paints its dropdown - the same sync point
  pmTimelinePopup gives the right-click menu, just for the menu bar. }
procedure TfrmMain.mnuTimelineClick(Sender: TObject);
begin
  SyncTimelineMenuState;
end;

{$IFNDEF FPC}
procedure TfrmMain.WMEnterMenuLoop(var Msg: TMessage);
begin
  FMenuLoopActive := True;
  inherited;
end;

procedure TfrmMain.WMExitMenuLoop(var Msg: TMessage);
begin
  FMenuLoopActive := False;
  inherited;
end;
{$ENDIF}

{ AFull=False (the per-tick path while the transport is running) only moves
  the playhead readout and repaints the canvas - it skips the menu sync
  above, the memo rebuild and the scrollbar resync, none of which change
  between ticks and all of which are wasted work at near-frame rate. }
procedure TfrmMain.RefreshTimelineTab(AFull: Boolean);
var
  tl: TTimeline;
  sel: TTimelineClip;
  trk: TTimelineTrack;
  i: Integer;
  kept: TArray<Integer>;
begin
  if FProject = nil then Exit;
  TlHealMissingEffectSources;
  tl := FProject.Timeline;

  { same TProjectDocument.TempoBPM the Project tab edits (TSetTempoCommand,
    undo-tracked) - not a separate value, so both tabs converge on the next
    refresh tick without any cross-tab notification. Skipped while the user
    is mid-edit here, mirroring edtProjectTempo's own Focused guard. }
  if not edtTlTempo.Focused then
    edtTlTempo.Text := FormatFloat('0.###', FProject.TempoBPM);

  FTlView.SetGrid(TimelineGrid);
  FTlView.SetHeaderWidth(tl.HeaderWidth);
  FTlView.SetViewportWidth(pbTimeline.Width);
  FTlView.SetContentSeconds(Max(30.0, tl.TotalDurationSeconds + 8.0));

  { Scroll-follow the playhead while the transport is running - TTimelinePlayer
    (the RT thread, see UDAW.Timeline.Playback.RenderBlock) already advances
    tl.PlayheadSeconds every render block; nothing was ever moving the
    VIEWPORT to keep up, so the line was genuinely advancing in the model but
    invisibly, since pbTimelinePaint only draws it when it falls within
    [HeaderWidth, w] - it just silently stopped being drawn the moment it
    scrolled past the right edge of whatever was on screen when Play was
    pressed. Only while playing: a paused/stopped transport must never fight
    a manual scroll/zoom the user is mid-gesture on. }
  if FTlPlaying then
    FTlView.EnsureVisible(tl.PlayheadSeconds);

  if (FTlSelClipId >= 0) and (tl.ClipById(FTlSelClipId) = nil) then
    FTlSelClipId := -1;

  { drop any multi-selected clip that no longer exists (deleted/undone
    elsewhere) so a stale id never reaches TlIsClipSelected/paint/delete }
  SetLength(kept, 0);
  for i := 0 to High(FTlSelClipIds) do
    if tl.ClipById(FTlSelClipIds[i]) <> nil then
    begin
      SetLength(kept, Length(kept) + 1);
      kept[High(kept)] := FTlSelClipIds[i];
    end;
  FTlSelClipIds := kept;

  lblTlPos.Caption := Format('Playhead  %s   %s   %s',
    [FormatBarsBeats(TimelineGrid, tl.PlayheadSeconds),
     FormatTimecode(tl.PlayheadSeconds),
     IfThen(FTlPlaying, '[PLAYING]', '')]);

  lblTlMasterVol.Caption := Format('Master Vol  %.1f dB', [tl.MasterVolumeDb]);
  if not FTlVolGuard then
  begin
    FTlVolGuard := True;
    try
      tbTlMasterVol.Position := Round(EnsureRange(tl.MasterVolumeDb, -60.0, 12.0));
    finally
      FTlVolGuard := False;
    end;
  end;

  if AFull then
  begin
    SyncTimelineMenuState;

    sel := nil;
    if FTlSelClipId >= 0 then
      sel := tl.ClipById(FTlSelClipId);
    if sel <> nil then
    begin
      tl.ClipById(FTlSelClipId, trk);
      memTimeline.Lines.Text := Format(
        'selected clip: "%s"  (id %d, track "%s")'#13#10 +
        '  start %.3f s   length %.3f s   source offset %.3f s   gain %.1f dB'#13#10 +
        '  fades %.3f / %.3f s   reversed %s   locked %s'#13#10#13#10 + '%s',
        [sel.Name, sel.Id, trk.Name, sel.StartSeconds, sel.LengthSeconds,
         sel.SourceOffsetSeconds, sel.GainDb, sel.FadeInSeconds, sel.FadeOutSeconds,
         BoolToStr(sel.Reversed, True), BoolToStr(sel.Locked, True), tl.Describe])
    end
    else
      memTimeline.Lines.Text := tl.Describe;

    SyncTimelineScrollbar;
  end
  else if FTlPlaying then
    { AFull is False on every per-tick playback refresh (see tmrUITimer), but
      the scrollbar thumb still has to track EnsureVisible's scrolling above,
      or it visibly lags/disagrees with the playhead the whole time the
      transport is running. }
    SyncTimelineScrollbar;

  pbTimeline.Invalidate;
end;

procedure TfrmMain.sbTlHorzChange(Sender: TObject);
begin
  if FTlScrollGuard then Exit;
  FTlView.ScrollToSeconds(sbTlHorz.Position / 10.0);
  pbTimeline.Invalidate;
end;

{ Vertical scroll of the channel list only - see TlTrackTop. The ruler and
  each track's own title band are drawn at fixed/relative-to-track positions
  untouched by FTlVScrollY, so they never move: the ruler always stays
  pinned to the top of the Timeline while the channels scroll beneath it. }
procedure TfrmMain.sbTlVertChange(Sender: TObject);
begin
  if FTlScrollGuard then Exit;
  FTlVScrollY := EnsureRange(sbTlVert.Position, 0, TlMaxVScroll);
  if sbTlVert.Position <> FTlVScrollY then
  begin
    { the native control itself let the thumb go past the valid range (see
      TlMaxVScroll's comment) - pull it back in sync with the clamped value
      instead of leaving it sitting somewhere pbTimeline never actually
      scrolls to, which was the flickering. }
    FTlScrollGuard := True;
    try
      sbTlVert.Position := FTlVScrollY;
    finally
      FTlScrollGuard := False;
    end;
  end;
  pbTimeline.Invalidate;
end;

procedure TfrmMain.edtTlTempoExit(Sender: TObject);
var
  tempo: Double;
begin
  if FProject = nil then Exit;
  { same TSetTempoCommand the Project tab's edtProjectTempo uses, so both
    fields share one undo history entry and stay in sync via RefreshTimelineTab
    / RefreshProjectTab's own next tick. }
  if TryStrToFloat(edtTlTempo.Text, tempo) and (tempo <> FProject.TempoBPM) then
    FCmds.Perform(TSetTempoCommand.Create(FProject, tempo))
  else
    edtTlTempo.Text := FormatFloat('0.###', FProject.TempoBPM);
end;

procedure TfrmMain.cboTlSnapChange(Sender: TObject);
const
  { Index-parallel with the cboTlSnap.Items.Add calls in FormCreate - smSample
    ("Realtime" in the dropdown, see SNAP_DISPLAY) is last. }
  MODES: array[0..8] of TSnapMode =
    (smOff, smBar, smBeat, smDiv2, smDiv4, smDiv8, smDiv16, smSecond, smSample);
begin
  if cboTlSnap.ItemIndex in [0..8] then
    FTlView.SnapMode := MODES[cboTlSnap.ItemIndex];
  pbTimeline.Invalidate;
end;

procedure TfrmMain.tbTlMasterVolChange(Sender: TObject);
begin
  if FTlVolGuard or (FProject = nil) then Exit;
  { A real gain stage (UDAW.Timeline.Playback.TTimelinePlayer.RenderBlock),
    not just a slider - and undo-safe/mergeable like every other DAW edit
    here, so riding this during playback is one undo step. }
  FCmds.Perform(TSetTimelineMasterVolumeCommand.Create(FProject, tbTlMasterVol.Position));
  lblTlMasterVol.Caption := Format('Master Vol  %.1f dB', [FProject.Timeline.MasterVolumeDb]);
end;

procedure TfrmMain.btnTlZoomInClick(Sender: TObject);
begin
  FTlView.ZoomBy(1.25, FTlView.HeaderWidth + TlLaneWidth div 2);
  RefreshTimelineTab;
end;

procedure TfrmMain.btnTlZoomOutClick(Sender: TObject);
begin
  FTlView.ZoomBy(0.8, FTlView.HeaderWidth + TlLaneWidth div 2);
  RefreshTimelineTab;
end;

{ Wheel up zooms in, wheel down zooms out, anchored under the cursor so the
  bar/second the mouse is pointing at stays put - the usual DAW/DAW-adjacent
  timeline convention - rather than always re-centring on the lane midpoint
  like the toolbar zoom buttons do. }
procedure TfrmMain.pbTimelineMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  anchorX: Integer;
  p: TPoint;
begin
  if FProject = nil then Exit;
  p := pbTimeline.ScreenToClient(MousePos);
  anchorX := p.X;
  if (anchorX < FTlView.HeaderWidth) or (anchorX > pbTimeline.Width) then
    anchorX := FTlView.HeaderWidth + TlLaneWidth div 2;
  if ssShift in Shift then
  begin
    { Shift+wheel: horizontal scroll instead of zoom - the FL-Studio-style
      convention, and the one gesture middle-mouse-drag panning doesn't cover
      (no button held). }
    if WheelDelta > 0 then
      FTlView.ScrollByPixels(-Round(TlLaneWidth * 0.15))
    else if WheelDelta < 0 then
      FTlView.ScrollByPixels(Round(TlLaneWidth * 0.15));
  end
  else if WheelDelta > 0 then
    FTlView.ZoomBy(1.25, anchorX)
  else if WheelDelta < 0 then
    FTlView.ZoomBy(0.8, anchorX);
  RefreshTimelineTab;
  Handled := True;
end;

procedure TfrmMain.btnTlUndoClick(Sender: TObject);
begin
  FCmds.Undo;
  RefreshTimelineTab;
end;

procedure TfrmMain.btnTlRedoClick(Sender: TObject);
begin
  FCmds.Redo;
  RefreshTimelineTab;
end;

{ ---- Timeline playback: Play renders the project's tracks/clips through
       UDAW.Timeline.Playback.TTimelinePlayer - the same non-destructive
       clip model the tab edits, so a clip moved/trimmed/muted or a track's
       gain/pan/mute/solo changed while the transport is running is heard
       on the very next block, no separate render/bounce step. Stop clears
       the engine source but leaves the playhead where it stopped, like a
       normal DAW transport (drag the ruler or click it to relocate). ---- }

{ Stops every transport (Timeline, tracker, audio graph, WAV/tone preview)
  and drops their playback state in one go, so loading a new/different
  project never leaves an old project's player, decode cache or engine
  source alive underneath the one that replaces it. }
procedure TfrmMain.StopAllPlayback;
begin
  StopTimelinePlayback;
  if FTrkPlaying or (FTrkPlayer <> nil) then
  begin
    if (App <> nil) and (App.Audio <> nil) then App.Audio.ClearSource;
    FTrkPlaying := False;
    FreeAndNil(FTrkPlayer);
    tmrUI.Interval := TRK_UI_IDLE_INTERVAL_MS;
  end;
  if FGraphPlaying then
  begin
    if (App <> nil) and (App.Audio <> nil) then App.Audio.ClearSource;
    FGraphPlaying := False;
    mnuGraphPlay.Caption := 'Play graph';
    pmGraphPlay.Caption := 'Play graph';
  end;
  if FWavPlaying then
  begin
    if (App <> nil) and (App.Audio <> nil) then App.Audio.ClearSource;
    FWavPlaying := False;
    FWavSource := nil;
    mnuWavPlay.Caption := 'Play';
    pmWavPlay.Caption := 'Play';
  end;
  if FTonePlaying then
  begin
    if (App <> nil) and (App.Audio <> nil) then App.Audio.ClearSource;
    FTonePlaying := False;
  end;
end;

{ Moves the playing/finished player's decoded + tempo-stretched caches into a
  spare player that outlives it, so the next Play reuses them (decoding and
  phase-vocoder stretching are expensive). }
procedure TfrmMain.ParkTimelineCache;
begin
  if (FTlPlayer = nil) or (FProject = nil) then Exit;
  if FTlCacheHolder = nil then FTlCacheHolder := TTimelinePlayer.Create(FProject.Timeline);
  FTlPlayer.SwapCacheWith(FTlCacheHolder);
end;

procedure TfrmMain.StopTimelinePlayback;
begin
  if FTlPrepJob <> nil then
  begin
    { still preparing: cancel; FinishTimelinePrepare frees the player once the
      worker has actually stopped touching it }
    FTlPrepCancelled := True;
    FTlPrepJob.Cancel;
    Exit;
  end;
  if not FTlPlaying then Exit;
  if (App <> nil) and (App.Audio <> nil) then
    App.Audio.ClearSource;
  FTlPlaying := False;
  FTlMeterL := 0;
  FTlMeterR := 0;
  pbTlMeters.Invalidate;
  ParkTimelineCache;
  FreeAndNil(FTlPlayer);
  FreeAndNil(FTlMixerProc);
  { Matches btnTrkStopClick's restore - see TRK_UI_PLAY_INTERVAL_MS's comment.
    Timeline and tracker playback are mutually exclusive (btnTlPlayClick
    clears FTrkPlaying and vice versa), so unconditionally dropping back to
    the idle rate here is safe: nothing else can still be relying on the
    fast tick. }
  tmrUI.Interval := TRK_UI_IDLE_INTERVAL_MS;
end;

{ Shared by every Play variant (Play/Play from Beginning/Play from Current/
  Play in Reverse/Play Ping Pong - both the main menu and pmTimeline carry
  all four). AFromBeginning relocates the playhead to 0 before starting;
  AReverse/APingPong set the new player's transport direction/bounce mode -
  see TTimelinePlayer.Direction/PingPong's comment for exactly how those
  interact with the region loop and the natural end-of-arrangement stop. }
procedure TfrmMain.StartTimelinePlayback(AFromBeginning, AReverse, APingPong: Boolean);
begin
  if (FProject = nil) or (App = nil) or (App.Audio = nil) then Exit;
  if FTlPrepJob <> nil then Exit;   // already preparing a previous Play

  FGraphPlaying := False;
  FWavPlaying := False;
  FTrkPlaying := False;
  FreeAndNil(FTrkPlayer);
  App.Audio.ClearSource;
  ParkTimelineCache;
  FreeAndNil(FTlPlayer);

  if AFromBeginning then
    FProject.Timeline.PlayheadSeconds := 0;

  if TlHealMissingEffectSources and (FTlCacheHolder <> nil) then
    FTlCacheHolder.InvalidateAll;   // repointed clips must not reuse stale decodes
  FTlPlayer := TTimelinePlayer.Create(FProject.Timeline);
  if FTlCacheHolder <> nil then FTlPlayer.SwapCacheWith(FTlCacheHolder);   // reuse decodes + stretches
  FTlPlayer.Direction := IfThen(AReverse, -1, 1);
  FTlPlayer.PingPong := APingPong;
  { Live tempo-follow: rate = current TempoBPM / tempo-at-Play, re-read every
    render block, so riding the Timeline/Project tempo field mid-playback
    actually changes playback speed instead of only affecting the grid. }
  FTlPlayer.SetTempoTracking(FProject.TempoBPM,
    function: Double
    begin
      if FProject <> nil then Result := FProject.TempoBPM else Result := 0;
    end);
  { Route any track a Mixer strip's InputSourceId names through the real
    TMixerProcessor, so that strip's fader/pan/inserts/sends/routing are
    actually audible instead of the Mixer tab being cosmetic. FTlMixerProc is
    (re)created fresh per Play so strip/routing edits made since the last
    Play always take effect; AttachMixer itself only records the reference -
    TTimelinePlayer.Prepare does the real (re)validation once the engine
    hands over the real sample rate/buffer size below, and silently falls
    back to direct per-track rendering if the mixer model is invalid (see
    that method's comment). }
  FreeAndNil(FTlMixerProc);
  FTlMixerProc := TMixerProcessor.Create(FProject.Mixer);
  FTlPlayer.AttachMixer(FTlMixerProc, FProject.Mixer);
  { Phase 38 - MIDI Timeline clips/live monitor: lets RenderBlock hear both
    committed MIDI clips on tkMidi tracks (AttachMidi) and whatever a
    connected MIDI controller is playing right now, live (AttachLiveMidi
    Monitor - see HandleLiveMidiInput). }
  FTlPlayer.AttachMidi(FProject.Midi);
  FTlPlayer.AttachLiveMidiMonitor(FMidiMonitorSynth);
  { "First render" of Timeline playback: every clip's backing media gets
    decoded synchronously right here (WAV/MP3/MP4), before a single frame of
    audio can play - can take real time for a project with many/long
    sources, so it gets the same status-bar progress treatment as import. }
  FTlPlayer.SetStretchTempo(FProject.TempoBPM);   // clips with a Source BPM conform to the timeline tempo
  FTlPlayer.SetMetronome(chkTlMetronome.Checked, FProject.TempoBPM, 4, -12);
  { Decoded sources and stretched copies are cached between Plays; they are
    only redone for a source/clip whose tempo actually changed. With a warm
    cache there is nothing to prepare, so skip the job and start immediately. }
  if not FTlPlayer.NeedsPrepare then
  begin
    memTimeline.Lines.Insert(0, 'Playback: decoded and tempo-stretched audio reused from cache - nothing to prepare.');
    BeginTimelineAudio;
    Exit;
  end;
  { Decode + tempo-stretch run as a background job so the window stays
    responsive; its stage text/progress reach the status bar via RefreshJobs.
    Playback actually starts in FinishTimelinePrepare once the job is done.
    The timeline canvas is disabled meanwhile so nothing edits the timeline
    under the worker thread. }
  FTlPrepJob := TTimelinePrepareJob.Create(FTlPlayer);
  try
    FTrackedJobs.Add(FTlPrepJob);
    App.Jobs.Submit(FTlPrepJob, False);
  except
    FTrackedJobs.Remove(FTlPrepJob);
    FreeAndNil(FTlPrepJob);
    raise;
  end;
  FTlPrepCancelled := False;
  pbTimeline.Enabled := False;
  tmrUI.Interval := TRK_UI_PLAY_INTERVAL_MS;   // poll the job quickly
  memTimeline.Lines.Insert(0, 'Preparing timeline playback in the background - see status bar.');
end;

{ Second half of StartTimelinePlayback, run from tmrUI once the prepare job is
  terminal. }
procedure TfrmMain.FinishTimelinePrepare;
var
  job: TTimelinePrepareJob;
begin
  if (FTlPrepJob = nil) or not FTlPrepJob.IsTerminal then Exit;
  job := FTlPrepJob;
  FTlPrepJob := nil;   // tracked jobs own the finished job until shutdown
  pbTimeline.Enabled := True;
  if FTlPrepCancelled or (job.Status <> jsSucceeded) then
  begin
    if job.Status = jsFailed then
      MessageDlg('Preparing timeline playback failed: ' + job.ErrorMessage, mtError, [mbOK], 0);
    ParkTimelineCache;
    FreeAndNil(FTlPlayer);
    FreeAndNil(FTlMixerProc);
    tmrUI.Interval := TRK_UI_IDLE_INTERVAL_MS;
    Exit;
  end;
  memTimeline.Lines.Insert(0, 'Playback ready: ' + job.Note);
  BeginTimelineAudio;
end;

{ Hands the prepared player to the audio engine and starts the transport UI. }
procedure TfrmMain.BeginTimelineAudio;
begin
  App.Audio.SetSource(FTlPlayer.AsSource);
  if (FTlMixerProc.LastError <> '') and not FTlMixerProc.IsPrepared then
    Logger.Warn('ui', 'Mixer routing is invalid (' + FTlMixerProc.LastError +
      ') - tracks linked to a Mixer strip will play back without it until this is fixed.');
  FTlPlaying := True;
  { tmrUI defaults to a 500ms idle poll (fine for log/jobs/meters), which
    only moved the Timeline's playhead line 2x/second during playback -
    far from "real-time". Raise it to the same ~30fps rate tracker playback
    already uses (see TRK_UI_PLAY_INTERVAL_MS) so RefreshTimelineTab's
    per-tick pbTimeline.Invalidate actually tracks the transport smoothly;
    StopTimelinePlayback restores the idle rate. }
  tmrUI.Interval := TRK_UI_PLAY_INTERVAL_MS;
  RefreshTimelineTab;
end;

procedure TfrmMain.btnTlPlayClick(Sender: TObject);
begin
  StartTimelinePlayback(False, False, False);
end;

{ ---- Play menu variants (mnuTlPlayFromBeginning/pmTlPlayFromBeginning etc.,
       alongside the existing mnuTlPlay/pmTlPlay "Play from current" button)
       requested for both the main menu bar and the Timeline popup menu. ---- }
procedure TfrmMain.TlPlayFromBeginningClick(Sender: TObject);
begin
  StartTimelinePlayback(True, False, False);
end;

procedure TfrmMain.TlPlayFromCurrentClick(Sender: TObject);
begin
  StartTimelinePlayback(False, False, False);
end;

procedure TfrmMain.TlPlayReverseClick(Sender: TObject);
begin
  StartTimelinePlayback(False, True, False);
end;

procedure TfrmMain.TlPlayPingPongClick(Sender: TObject);
begin
  StartTimelinePlayback(False, False, True);
end;

{ "Export final mix..." used to be one flat item that opened the dialog with
  whatever format the user last picked in its filter dropdown. It is now an
  "Export" submenu (Timeline menu / pmTimeline) with one entry per format -
  WAV/MP3/MP4/FLAC - each just pre-selecting that format's FilterIndex before
  reusing the same dialog + job-submission path. dlgTimelineExport's Filter
  string (see the .dfm) still lists M4A/PCM too, so typing either extension
  by hand in the dialog keeps working even without its own menu entry. }
{ True when the timeline holds at least one video clip. Video changes what an
  export can be: only a video container (MP4 / MKV) can carry it, so the
  export dialog offers just those two formats while video is present. }
function TfrmMain.TlHasVideo: Boolean;
var
  i: Integer;
begin
  Result := False;
  if FProject = nil then Exit;
  for i := 0 to FProject.Timeline.TrackCount - 1 do
    if (FProject.Timeline.GetTrack(i).Kind = tkVideo) and
       (FProject.Timeline.GetTrack(i).ClipCount > 0) then
      Exit(True);
end;

{ Runs dlgTimelineExport, swapping its filter to MP4/MKV only while video is
  on the timeline. Returns the chosen path with a default extension applied. }
function TfrmMain.ExecuteTimelineExportDialog(AFilterIndex: Integer; out ADest: string): Boolean;
const
  Extensions: array[1..6] of string = ('.wav', '.mp3', '.mp4', '.m4a', '.pcm', '.flac');
  VideoExtensions: array[1..2] of string = ('.mp4', '.mkv');
var
  audioFilter: string;
  videoMode: Boolean;
begin
  audioFilter := dlgTimelineExport.Filter;
  videoMode := TlHasVideo;
  try
    if videoMode then
    begin
      dlgTimelineExport.Filter := 'MP4 - video with AAC audio|*.mp4|MKV - video with audio|*.mkv';
      dlgTimelineExport.FilterIndex := 1;
    end
    else
      dlgTimelineExport.FilterIndex := AFilterIndex;
    dlgTimelineExport.InitialDir := edDirExport.Text;
    Result := dlgTimelineExport.Execute;
    if not Result then Exit;
    ADest := dlgTimelineExport.FileName;
    if ExtractFileExt(ADest) = '' then
    begin
      if videoMode then ADest := ADest + VideoExtensions[dlgTimelineExport.FilterIndex]
      else ADest := ADest + Extensions[dlgTimelineExport.FilterIndex];
      if FileExists(ADest) and (MessageDlg('Replace ' + ADest + '?',
        mtConfirmation, [mbYes, mbNo], 0) <> mrYes) then Result := False;
    end
    else if videoMode and not (SameText(ExtractFileExt(ADest), '.mp4') or
      SameText(ExtractFileExt(ADest), '.mkv')) then
    begin
      MessageDlg('A timeline with video can only be exported as MP4 or MKV.', mtInformation, [mbOK], 0);
      Result := False;
    end;
  finally
    dlgTimelineExport.Filter := audioFilter;
  end;
end;

procedure TfrmMain.RunTimelineExport(AFilterIndex: Integer);
var
  dest: string;
begin
  if not RequireRegistration('Exporting the timeline') then Exit;
  if (FProject = nil) or (FTimelineExportJob <> nil) then Exit;
  if not ExecuteTimelineExportDialog(AFilterIndex, dest) then Exit;
  StartTimelineExportJob(dest);
end;

procedure TfrmMain.pmTlExportWavClick(Sender: TObject);
begin
  RunTimelineExport(1);
end;

procedure TfrmMain.pmTlExportMp3Click(Sender: TObject);
begin
  RunTimelineExport(2);
end;

procedure TfrmMain.pmTlExportMp4Click(Sender: TObject);
begin
  RunTimelineExport(3);
end;

procedure TfrmMain.pmTlExportFlacClick(Sender: TObject);
begin
  RunTimelineExport(6);
end;

{ Save Selection as WAV/PCM/FLAC: renders just the highlighted range (all
  channels mixed, through the mixer) via the normal export job. Tag = the
  dlgTimelineExport filter index (1 WAV, 5 PCM, 6 FLAC). }
procedure TfrmMain.TlSaveSelectionClick(Sender: TObject);
var
  dest: string;
  idx: Integer;
begin
  if not RequireRegistration('Exporting the timeline') then Exit;
  if (FProject = nil) or (FTimelineExportJob <> nil) or not FTlRangeActive or
     (FTlRangeEndSec <= FTlRangeStartSec) then Exit;
  idx := (Sender as TComponent).Tag;
  if not ExecuteTimelineExportDialog(idx, dest) then Exit;
  StartTimelineExportJob(dest, FTlRangeStartSec, FTlRangeEndSec);
end;

procedure TfrmMain.StartTimelineExportJob(const ADest: string;
  ARangeStart, ARangeEnd: Double);
begin
  { Video needs a video muxer (MP4/MKV writer that carries the video clips
    plus the mixed audio). That writer is not built yet; exporting through
    the audio-only path would silently drop the video, so refuse plainly. }
  if TlHasVideo then
  begin
    MessageDlg('This timeline contains video. Video export (MP4 / MKV) needs the video muxer, ' +
      'which is not available yet. Remove the video channel to export the audio mix, ' +
      'or keep working - your video clips are saved with the project.', mtInformation, [mbOK], 0);
    Exit;
  end;
  try
    if ARangeEnd > ARangeStart then
      FTimelineExportJob := TTimelineExportJob.Create(FProject, ADest, ARangeStart, ARangeEnd)
    else
      FTimelineExportJob := TTimelineExportJob.Create(FProject, ADest);
    try
      FTrackedJobs.Add(FTimelineExportJob);
      App.Jobs.Submit(FTimelineExportJob, False);
    except
      FTrackedJobs.Remove(FTimelineExportJob);
      FreeAndNil(FTimelineExportJob);
      raise;
    end;
    FTlExportLastStage := '';
    memTimeline.Lines.Insert(0, 'Export queued: ' + ADest +
      '. Progress appears in the status bar and Jobs. Use Jobs > Cancel all to cancel.');
  except
    on E: Exception do MessageDlg('Export failed: ' + E.Message, mtError, [mbOK], 0);
  end;
end;

procedure TfrmMain.TrackTimelineExportStage;
var
  note, stage: string;
  p: Integer;
begin
  if FTimelineExportJob = nil then Exit;
  note := FTimelineExportJob.Note;
  if not note.StartsWith('Stage ') then Exit;
  p := Pos(':', note);
  if p = 0 then Exit;
  stage := Copy(note, 1, p - 1);
  if stage = FTlExportLastStage then Exit;
  FTlExportLastStage := stage;
  memTimeline.Lines.Insert(0, 'Export ' + note);
end;

procedure TfrmMain.FinishTimelineExport;
var
  job: TTimelineExportJob;
begin
  if (FTimelineExportJob = nil) or not FTimelineExportJob.IsTerminal then Exit;
  job := FTimelineExportJob;
  FTimelineExportJob := nil; // tracked jobs own the completed job until shutdown
  if job.Status = jsFailed then
    MessageDlg('Timeline export failed: ' + job.ErrorMessage, mtError, [mbOK], 0)
  else if job.Status = jsSucceeded then
    memTimeline.Lines.Insert(0, job.Note)
  else
    memTimeline.Lines.Insert(0, 'Timeline export cancelled.');
end;

procedure TfrmMain.btnTlStopClick(Sender: TObject);
begin
  StopTimelinePlayback;
  RefreshTimelineTab;
end;

{ ---- Cut / Copy / Paste: clipboard is a single in-memory TClipState held
       across calls, mirroring how the undo commands snapshot a clip. ---- }
procedure TfrmMain.btnTlCopyClick(Sender: TObject);
var
  tl: TTimeline;
  trk: TTimelineTrack;
  c: TTimelineClip;
begin
  if (FProject = nil) or (FTlSelClipId < 0) then Exit;
  tl := FProject.Timeline;
  c := tl.ClipById(FTlSelClipId, trk);
  if c = nil then Exit;
  FTlClipboard.Id := c.Id;
  FTlClipboard.TrackId := trk.Id;
  FTlClipboard.SourceId := c.SourceId;
  FTlClipboard.Name := c.Name;
  FTlClipboard.StartSeconds := c.StartSeconds;
  FTlClipboard.SourceOffsetSeconds := c.SourceOffsetSeconds;
  FTlClipboard.LengthSeconds := c.LengthSeconds;
  FTlClipboard.GainDb := c.GainDb;
  FTlClipboard.FadeInSeconds := c.FadeInSeconds;
  FTlClipboard.FadeOutSeconds := c.FadeOutSeconds;
  FTlClipboard.FadeInShape := c.FadeInShape;
  FTlClipboard.FadeOutShape := c.FadeOutShape;
  FTlClipboard.Reversed := c.Reversed;
  FTlClipboard.Muted := c.Muted;
  FTlClipboard.Locked := False;   // a paste should never be born locked
  FTlClipboard.Loop := c.Loop;
  FTlClipboard.Color := c.Color;
  FTlHaveClipboard := True;
  memTimeline.Lines.Insert(0, Format('Copied clip "%s"', [c.Name]));
end;

procedure TfrmMain.btnTlCutClick(Sender: TObject);
begin
  if (FProject = nil) or (FTlSelClipId < 0) then Exit;
  btnTlCopyClick(Sender);
  try
    FCmds.Perform(TRemoveTimelineClipCommand.Create(FProject, FTlSelClipId));
    FTlSelClipId := -1;
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'Cut FAILED: ' + E.Message);
  end;
end;

procedure TfrmMain.btnTlPasteClick(Sender: TObject);
var
  tl: TTimeline;
  addCmd: TAddTimelineClipCommand;
  c: TTimelineClip;
  destTrackId: Integer;
begin
  if (FProject = nil) or not FTlHaveClipboard then Exit;
  tl := FProject.Timeline;
  { paste onto the active (selected) channel, not the channel copied from }
  destTrackId := FTlSelectedTrackId;
  if (destTrackId < 0) or (tl.TrackById(destTrackId) = nil) then
    destTrackId := FTlClipboard.TrackId;
  if tl.TrackById(destTrackId) = nil then
  begin
    { no active channel and the source track was removed since copying - fall
      back to the first audio track rather than silently failing the paste. }
    destTrackId := TlFirstAudioTrackId;
    if destTrackId < 0 then Exit;
  end;
  try
    addCmd := TAddTimelineClipCommand.Create(FProject, destTrackId, FTlClipboard.SourceId,
      FTlClipboard.Name, FTlView.Snap(tl.PlayheadSeconds), FTlClipboard.SourceOffsetSeconds,
      FTlClipboard.LengthSeconds);
    FCmds.Perform(addCmd);
    { restore the gain/fade/reverse/mute state that a bare add-clip doesn't carry }
    c := tl.ClipById(addCmd.CreatedId);
    if c <> nil then
    begin
      c.GainDb := FTlClipboard.GainDb;
      c.FadeInSeconds := FTlClipboard.FadeInSeconds;
      c.FadeOutSeconds := FTlClipboard.FadeOutSeconds;
      c.FadeInShape := FTlClipboard.FadeInShape;
      c.FadeOutShape := FTlClipboard.FadeOutShape;
      c.Reversed := FTlClipboard.Reversed;
      c.Muted := FTlClipboard.Muted;
      c.Color := FTlClipboard.Color;
    end;
    FTlSelClipId := addCmd.CreatedId;
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'Paste FAILED: ' + E.Message);
  end;
end;

{ Copy Selection: snapshots every clip overlapping the active range
  selection (FTlRangeStartSec/FTlRangeEndSec), across every channel, keyed
  by its offset from the range start and its channel index relative to
  the channel that is active (FTlSelectedTrackId) at copy time. }
procedure TfrmMain.pmTlCopySelectionClick(Sender: TObject);
var
  tl: TTimeline;
  ti, j, activeIdx, n: Integer;
  trk: TTimelineTrack;
  c: TTimelineClip;
begin
  if (FProject = nil) or not FTlRangeActive then Exit;
  tl := FProject.Timeline;
  activeIdx := tl.IndexOfTrack(FTlSelectedTrackId);
  if activeIdx < 0 then activeIdx := 0;
  SetLength(FTlSelectionClipboard, 0);
  SetLength(FTlSelectionClipboardRelStart, 0);
  SetLength(FTlSelectionClipboardRelTrack, 0);
  n := 0;
  for ti := 0 to tl.TrackCount - 1 do
  begin
    trk := tl.GetTrack(ti);
    for j := 0 to trk.ClipCount - 1 do
    begin
      c := trk.GetClip(j);
      if (c.StartSeconds >= FTlRangeStartSec - TIMELINE_MIN_CLIP_SECONDS) and
         (c.EndSeconds <= FTlRangeEndSec + TIMELINE_MIN_CLIP_SECONDS) then
      begin
        Inc(n);
        SetLength(FTlSelectionClipboard, n);
        SetLength(FTlSelectionClipboardRelStart, n);
        SetLength(FTlSelectionClipboardRelTrack, n);
        FTlSelectionClipboard[n - 1].Id := c.Id;
        FTlSelectionClipboard[n - 1].TrackId := trk.Id;
        FTlSelectionClipboard[n - 1].SourceId := c.SourceId;
        FTlSelectionClipboard[n - 1].Name := c.Name;
        FTlSelectionClipboard[n - 1].StartSeconds := c.StartSeconds;
        FTlSelectionClipboard[n - 1].SourceOffsetSeconds := c.SourceOffsetSeconds;
        FTlSelectionClipboard[n - 1].LengthSeconds := c.LengthSeconds;
        FTlSelectionClipboard[n - 1].GainDb := c.GainDb;
        FTlSelectionClipboard[n - 1].FadeInSeconds := c.FadeInSeconds;
        FTlSelectionClipboard[n - 1].FadeOutSeconds := c.FadeOutSeconds;
        FTlSelectionClipboard[n - 1].FadeInShape := c.FadeInShape;
        FTlSelectionClipboard[n - 1].FadeOutShape := c.FadeOutShape;
        FTlSelectionClipboard[n - 1].Reversed := c.Reversed;
        FTlSelectionClipboard[n - 1].Muted := c.Muted;
        FTlSelectionClipboard[n - 1].Locked := False;
        FTlSelectionClipboard[n - 1].Loop := c.Loop;
        FTlSelectionClipboard[n - 1].Color := c.Color;
        FTlSelectionClipboardRelStart[n - 1] := c.StartSeconds - FTlRangeStartSec;
        FTlSelectionClipboardRelTrack[n - 1] := ti - activeIdx;
      end;
    end;
  end;
  FTlHaveSelectionClipboard := (n > 0);
  if FTlHaveSelectionClipboard then
    memTimeline.Lines.Insert(0, Format('Copied selection (%d clip(s))', [n]))
  else
    memTimeline.Lines.Insert(0, 'Copy Selection: nothing in range');
end;

{ Paste Selection: re-creates the copied group anchored on the playhead and
  on whichever channel is active NOW (FTlSelectedTrackId), preserving each
  clip's relative timing and relative channel offset from copy time. Clips
  whose relative channel falls outside the current channel list are dropped
  onto the nearest in-range channel rather than silently lost. }
procedure TfrmMain.pmTlPasteSelectionClick(Sender: TObject);
var
  tl: TTimeline;
  i, activeIdx, destIdx: Integer;
  destTrackId: Integer;
  addCmd: TAddTimelineClipCommand;
  c: TTimelineClip;
  anchorSec: Double;
begin
  if (FProject = nil) or not FTlHaveSelectionClipboard then Exit;
  tl := FProject.Timeline;
  if tl.TrackCount = 0 then Exit;
  activeIdx := tl.IndexOfTrack(FTlSelectedTrackId);
  if activeIdx < 0 then activeIdx := 0;
  anchorSec := FTlView.Snap(tl.PlayheadSeconds);
  try
    for i := 0 to High(FTlSelectionClipboard) do
    begin
      destIdx := EnsureRange(activeIdx + FTlSelectionClipboardRelTrack[i], 0, tl.TrackCount - 1);
      destTrackId := tl.GetTrack(destIdx).Id;
      addCmd := TAddTimelineClipCommand.Create(FProject, destTrackId, FTlSelectionClipboard[i].SourceId,
        FTlSelectionClipboard[i].Name, anchorSec + FTlSelectionClipboardRelStart[i],
        FTlSelectionClipboard[i].SourceOffsetSeconds, FTlSelectionClipboard[i].LengthSeconds);
      FCmds.Perform(addCmd);
      c := tl.ClipById(addCmd.CreatedId);
      if c <> nil then
      begin
        c.GainDb := FTlSelectionClipboard[i].GainDb;
        c.FadeInSeconds := FTlSelectionClipboard[i].FadeInSeconds;
        c.FadeOutSeconds := FTlSelectionClipboard[i].FadeOutSeconds;
        c.FadeInShape := FTlSelectionClipboard[i].FadeInShape;
        c.FadeOutShape := FTlSelectionClipboard[i].FadeOutShape;
        c.Reversed := FTlSelectionClipboard[i].Reversed;
        c.Muted := FTlSelectionClipboard[i].Muted;
        c.Color := FTlSelectionClipboard[i].Color;
      end;
    end;
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'Paste Selection FAILED: ' + E.Message);
  end;
end;

{ ---- Track reorder ---- }
procedure TfrmMain.btnTlTrackUpClick(Sender: TObject);
var
  tl: TTimeline;
  idx: Integer;
begin
  if (FProject = nil) or (FTlCtxTrackId < 0) then Exit;
  tl := FProject.Timeline;
  idx := tl.IndexOfTrack(FTlCtxTrackId);
  if idx <= 0 then Exit;
  try
    FCmds.Perform(TMoveTimelineTrackCommand.Create(FProject, FTlCtxTrackId, idx - 1));
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'Move Track Up FAILED: ' + E.Message);
  end;
end;

procedure TfrmMain.btnTlTrackDownClick(Sender: TObject);
var
  tl: TTimeline;
  idx: Integer;
begin
  if (FProject = nil) or (FTlCtxTrackId < 0) then Exit;
  tl := FProject.Timeline;
  idx := tl.IndexOfTrack(FTlCtxTrackId);
  if (idx < 0) or (idx >= tl.TrackCount - 1) then Exit;
  try
    FCmds.Perform(TMoveTimelineTrackCommand.Create(FProject, FTlCtxTrackId, idx + 1));
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'Move Track Down FAILED: ' + E.Message);
  end;
end;

{ Auto-titling: whenever any effect insert is added to a mixer strip that
  backs a real Timeline track, append the effect's name to that track's own
  title band (TTimelineTrack.Title, drawn directly over that channel in
  pbTimelinePaint - see TlTrackTitleRect) so it is never forgotten. A strip
  with no matching track (bus/aux/VCA/master) has no channel on the Timeline
  to put it on, so those are silently skipped. Title is a plain persisted
  field on the track, saved with the project. }
procedure TfrmMain.TlNoteEffectAdded(AStripId: Integer; const AEffectName: string);
begin
  { Intentionally no longer appends to the track-wide Title: that piled every
    effect name at the start of the channel. Effect names are shown per region,
    only where each effect is actually present (see the region loop in
    pbTimelinePaint). }
end;

{ Maps a rendered effect's display name (exactly as passed to
  TlApplyEffectToRange / TlApplySilenceToRange, e.g. 'Compressor',
  'Bit Crusher') onto its user-editable swatch on the Colors settings page
  (UDAW.UI.ThemeColors' Fx* fields), so a clip that has had an effect
  rendered onto it is painted in that effect's assigned colour rather than
  the generic "has effects" tint. Falls back to ClipEffectsBackground for an
  effect name that has no dedicated swatch. }
{ Every effect region drawn on a clip. Clips from projects saved before the
  region list existed only carry the single EffectName/Offset/Length, so that
  one is presented as a one-entry list. }
function TfrmMain.TlClipRegions(AClip: TTimelineClip): TArray<TClipEffectRegion>;
begin
  if Length(AClip.EffectRegions) > 0 then
    Exit(AClip.EffectRegions);
  SetLength(Result, 0);
  if AClip.EffectName = '' then Exit;
  SetLength(Result, 1);
  Result[0].Name := AClip.EffectName;
  Result[0].OffsetSeconds := AClip.EffectOffsetSeconds;
  Result[0].LengthSeconds := AClip.EffectLengthSeconds;
  Result[0].Color := AClip.Color;
end;

function TfrmMain.TlEffectColor(const AEffectName: string): TColor;
var
  theme: TUDAWTheme;
begin
  theme := ThemeColorsCurrent;
  if SameText(AEffectName, 'Fade In') then Result := theme.FadeInBackground
  else if SameText(AEffectName, 'Fade Out') then Result := theme.FadeOutBackground
  else if SameText(AEffectName, 'Compressor') then Result := theme.FxCompressor
  else if SameText(AEffectName, 'Reverb') then Result := theme.FxReverb
  else if SameText(AEffectName, 'Chorus') then Result := theme.FxChorus
  else if SameText(AEffectName, 'Flanger') then Result := theme.FxFlanger
  else if SameText(AEffectName, 'Phaser') then Result := theme.FxPhaser
  else if SameText(AEffectName, 'Tremolo') then Result := theme.FxTremolo
  else if SameText(AEffectName, 'Auto-Pan') then Result := theme.FxAutoPan
  else if SameText(AEffectName, 'Saturation') then Result := theme.FxSaturation
  else if SameText(AEffectName, 'Bit Crusher') then Result := theme.FxBitCrusher
  else if SameText(AEffectName, 'Brighten EQ') then Result := theme.FxBrightenEQ
  else if SameText(AEffectName, 'Silence') then Result := theme.FxSilence
  else if SameText(AEffectName, 'Amplify') then Result := theme.FxAmplify
  else if SameText(AEffectName, 'De-Esser') then Result := theme.FxDeEsser
  else if SameText(AEffectName, 'Delay') then Result := theme.FxDelay
  else if SameText(AEffectName, 'Expander') then Result := theme.FxExpander
  else if SameText(AEffectName, 'Foldback') then Result := theme.FxFoldback
  else if SameText(AEffectName, 'Gate') then Result := theme.FxGate
  else if SameText(AEffectName, 'Hard Clip') then Result := theme.FxHardClip
  else if SameText(AEffectName, 'Limiter') then Result := theme.FxLimiter
  else if SameText(AEffectName, 'Ping-Pong Delay') then Result := theme.FxPingPongDelay
  else if SameText(AEffectName, 'Balance') then Result := theme.FxBalance
  else if SameText(AEffectName, 'Bass Enhance') then Result := theme.FxBassEnhance
  else if SameText(AEffectName, 'DC Offset Remover') then Result := theme.FxDCOffsetRemover
  else if SameText(AEffectName, 'Exciter') then Result := theme.FxExciter
  else if SameText(AEffectName, 'High-Pass Filter') then Result := theme.FxHighPassFilter
  else if SameText(AEffectName, 'Low-Pass Filter') then Result := theme.FxLowPassFilter
  else if SameText(AEffectName, 'Make Mono') then Result := theme.FxMakeMono
  else if SameText(AEffectName, 'Multiband Compressor') then Result := theme.FxMultibandCompressor
  else if SameText(AEffectName, 'Notch Filter') then Result := theme.FxNotchFilter
  else if SameText(AEffectName, 'Pitch Shift') then Result := theme.FxPitchShift
  else if SameText(AEffectName, 'Presence Boost') then Result := theme.FxPresenceBoost
  else if SameText(AEffectName, 'Stereo Widener') then Result := theme.FxStereoWidener
  else if SameText(AEffectName, 'Transient Shaper') then Result := theme.FxTransientShaper
  else if SameText(AEffectName, 'Treble Boost') then Result := theme.FxTrebleBoost
  else Result := theme.ClipEffectsBackground;
end;

{ Mute Track (Timeline menu / pmTimeline / mnuTlTrack): unlike the old
  instant-toggle-on-right-click behaviour, this now only fires from the menu
  item, so a plain right-click always opens the context menu first. Not run
  through the undo stack - like the Mixer's chkMixMute checkbox, this is a
  live monitoring toggle, not a structural edit; TTimelinePlayer reads
  trk.Muted live per-sample so it takes effect immediately mid-playback. }
procedure TfrmMain.pmTlMuteTrackClick(Sender: TObject);
var
  trk: TTimelineTrack;
begin
  if (FProject = nil) or (FTlCtxTrackId < 0) then Exit;
  trk := FProject.Timeline.TrackById(FTlCtxTrackId);
  if trk = nil then Exit;
  trk.Muted := not trk.Muted;
  FProject.Touch;
  RefreshTimelineTab;
end;

{ Rename Track (Timeline Edit menu / pmTimeline): undoable, mirrors
  TMoveTimelineTrackCommand's shape. }
procedure TfrmMain.pmTlRenameTrackClick(Sender: TObject);
var
  trk: TTimelineTrack;
  newName: string;
begin
  if (FProject = nil) or (FTlCtxTrackId < 0) then Exit;
  trk := FProject.Timeline.TrackById(FTlCtxTrackId);
  if trk = nil then Exit;
  newName := trk.Name;
  if not InputQuery('Rename Track', 'Track name:', newName) then Exit;
  newName := Trim(newName);
  if (newName = '') or (newName = trk.Name) then Exit;
  try
    FCmds.Perform(TRenameTimelineTrackCommand.Create(FProject, FTlCtxTrackId, newName));
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'Rename Track FAILED: ' + E.Message);
  end;
end;

{ ---- Position navigation (Timeline menu / pmTimeline "Position" group) ---- }

{ Grid step for Next/Previous Grid Position: the active Snap mode's spacing,
  except smSample ("Realtime" in the snap dropdown) which is too fine to be a
  meaningful "next/previous" step - that one moves by a whole second instead,
  same as smOff (no grid) falling back to whole seconds too. }
function TfrmMain.TlNavStepSeconds: Double;
begin
  if FTlView.SnapMode = smSample then Exit(1.0);
  Result := GridSpacingSeconds(TimelineGrid, FTlView.SnapMode);
  if Result <= 0 then Result := 1.0;
end;

function TfrmMain.TlNavTargetTrack: TTimelineTrack;
var
  tl: TTimeline;
begin
  Result := nil;
  if FProject = nil then Exit;
  tl := FProject.Timeline;
  if FTlSelectedTrackId >= 0 then Result := tl.TrackById(FTlSelectedTrackId);
  if Result = nil then Result := tl.TrackById(FTlCtxTrackId);
end;

procedure TfrmMain.pmTlNavNextClick(Sender: TObject);
var
  tl: TTimeline;
begin
  if FProject = nil then Exit;
  tl := FProject.Timeline;
  tl.PlayheadSeconds := tl.PlayheadSeconds + TlNavStepSeconds;
  RefreshTimelineTab;
end;

procedure TfrmMain.pmTlNavPrevClick(Sender: TObject);
var
  tl: TTimeline;
begin
  if FProject = nil then Exit;
  tl := FProject.Timeline;
  tl.PlayheadSeconds := Max(0.0, tl.PlayheadSeconds - TlNavStepSeconds);
  RefreshTimelineTab;
end;

{ Jumps the playhead to the very start of the timeline (time 0). }
procedure TfrmMain.pmTlJumpElementStartClick(Sender: TObject);
begin
  if FProject = nil then Exit;
  FProject.Timeline.PlayheadSeconds := 0.0;
  RefreshTimelineTab;
end;

{ Jumps the playhead to the end of the timeline: if a track is currently
  selected (or was last right-clicked), uses that track's own end so the
  jump follows whichever timeline/track is in focus; otherwise uses the end
  of the whole project timeline (furthest clip/region end across all tracks). }
procedure TfrmMain.pmTlJumpElementEndClick(Sender: TObject);
var
  trk: TTimelineTrack;
begin
  if FProject = nil then Exit;
  trk := TlNavTargetTrack;
  if trk <> nil then
    FProject.Timeline.PlayheadSeconds := trk.LastEndSeconds
  else
    FProject.Timeline.PlayheadSeconds := FProject.Timeline.TotalDurationSeconds;
  RefreshTimelineTab;
end;

{ ---- Loop region: stored on TTimeline (LoopStartSeconds/LoopLengthSeconds/
       LoopEnabled), drawn as a shaded band on the ruler in pbTimelinePaint,
       and honoured by TTimelinePlayer.RenderBlock when LoopEnabled is set. }
procedure TfrmMain.btnTlLoopStartClick(Sender: TObject);
var
  tl: TTimeline;
  newLen: Double;
begin
  if FProject = nil then Exit;
  tl := FProject.Timeline;
  newLen := (tl.LoopStartSeconds + tl.LoopLengthSeconds) - tl.PlayheadSeconds;
  tl.LoopStartSeconds := tl.PlayheadSeconds;
  if newLen > 0 then
    tl.LoopLengthSeconds := newLen
  else if tl.LoopLengthSeconds <= 0 then
    tl.LoopLengthSeconds := 4.0;   // sensible default so a fresh loop is visible/audible
  FProject.Touch;
  RefreshTimelineTab;
end;

procedure TfrmMain.btnTlLoopEndClick(Sender: TObject);
var
  tl: TTimeline;
  newLen: Double;
begin
  if FProject = nil then Exit;
  tl := FProject.Timeline;
  newLen := tl.PlayheadSeconds - tl.LoopStartSeconds;
  if newLen > 0 then
    tl.LoopLengthSeconds := newLen;
  FProject.Touch;
  RefreshTimelineTab;
end;

procedure TfrmMain.btnTlLoopToggleClick(Sender: TObject);
var
  tl: TTimeline;
begin
  if FProject = nil then Exit;
  tl := FProject.Timeline;
  tl.LoopEnabled := not tl.LoopEnabled;
  FProject.Touch;
  RefreshTimelineTab;
end;

procedure TfrmMain.AdvanceTimelinePlayback;
begin
  if not FTlPlaying then Exit;
  if (FTlPlayer <> nil) and FTlPlayer.ReachedEnd then
  begin
    { RenderBlock (RT thread) reached the end of the arrangement with the
      region loop off - stop the transport here on the UI thread, like a
      normal DAW does at the end of the song, instead of leaving it running
      into silence forever. See TTimelinePlayer.ReachedEnd's comment. }
    StopTimelinePlayback;
    { User requirement: playback that runs out naturally (unlike a manual
      Stop click) rewinds the playhead to 0, like a normal DAW transport. }
    FProject.Timeline.PlayheadSeconds := 0;
  FRecInsertSeconds := 0;
    RefreshTimelineTab;
    Exit;
  end;
  { UI-thread only: safe to decode newly-added sources here (never on
    Render, the real-time path - see UDAW.Timeline.Playback's header). }
  if FTlPlayer <> nil then
    FTlPlayer.EnsureSourcesLoaded;
end;

procedure TfrmMain.btnTlAddTrackClick(Sender: TObject);
begin
  try
    FCmds.Perform(TAddTimelineTrackCommand.Create(FProject, tkAudio,
      Format('Audio %d', [FProject.Timeline.TrackCount + 1])));
    EnsureMixerStripsForTimelineTracks;
    { the fresh channel becomes the active one, so Paste lands on it }
    FTlSelectedTrackId := FProject.Timeline.GetTrack(FProject.Timeline.TrackCount - 1).Id;
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'Add track FAILED: ' + E.Message);
  end;
end;

procedure TfrmMain.btnTlAddClipClick(Sender: TObject);
var
  info: TWavInfo;
  tl: TTimeline;
  src: TMediaSource;
  trackId: Integer;
  addCmd: TAddTimelineClipCommand;
  lenSec: Double;
begin
  if FProject = nil then Exit;
  if not dlgOpenWav.Execute then Exit;
  try
    if not FileLooksLikeWav(dlgOpenWav.FileName) then
    begin
      memTimeline.Lines.Insert(0, 'not a WAV file: ' + dlgOpenWav.FileName);
      Exit;
    end;
    info := ReadWavInfo(dlgOpenWav.FileName);
    tl := FProject.Timeline;

    trackId := TlNewAudioTrackId;

    src := tl.AddSource(dlgOpenWav.FileName, info.SampleRate, info.Channels, info.FrameCount);
    lenSec := info.DurationSeconds;
    if lenSec > 60 then lenSec := 60;
    if lenSec < 0.001 then lenSec := 0.001;

    addCmd := TAddTimelineClipCommand.Create(FProject, trackId, src.Id,
      ExtractFileName(dlgOpenWav.FileName), FTlView.Snap(tl.PlayheadSeconds), 0, lenSec);
    FCmds.Perform(addCmd);
    WarmClipWaveform(src.Id);
    FTlSelClipId := addCmd.CreatedId;
    Logger.Info('ui', 'timeline clip added from ' + dlgOpenWav.FileName);
    ApplyBaselineTempoOnImport(addCmd.CreatedId);
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'Add clip FAILED: ' + E.Message);
  end;
end;

procedure TfrmMain.btnTlSplitClick(Sender: TObject);
var
  c: TTimelineClip;
begin
  if (FProject = nil) or (FTlSelClipId < 0) then Exit;
  c := FProject.Timeline.ClipById(FTlSelClipId);
  if (c = nil) or not c.ContainsSeconds(FProject.Timeline.PlayheadSeconds) then
  begin
    memTimeline.Lines.Insert(0, 'put the playhead inside the selected clip to split it');
    Exit;
  end;
  try
    FCmds.Perform(TSplitTimelineClipCommand.Create(FProject, FTlSelClipId,
      FProject.Timeline.PlayheadSeconds));
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'Split FAILED: ' + E.Message);
  end;
end;

{ ---- Range/section editing: acts on every clip on every track that falls
  inside [FTlRangeStartSec, FTlRangeEndSec) - the ruler drag-selection, not
  the clip multi-select - so one gesture can touch several tracks at once,
  like a Pro Tools/Reaper time-selection edit. ---- }

{ Splits every clip that straddles either range boundary, on every track, so
  the piece of each clip inside the range becomes its own clip. Safe to call
  with no clips actually crossing a boundary (a no-op then). Re-fetches each
  clip after the first split since TSplitTimelineClipCommand shrinks the
  original clip to the left piece and the boundary check must run against
  its new bounds. }
procedure TfrmMain.TlSplitAtRangeEdges;
var
  tl: TTimeline;
  ti, j: Integer;
  trk: TTimelineTrack;
  ids: TArray<Integer>;
  id: Integer;
  c: TTimelineClip;
begin
  if FProject = nil then Exit;
  tl := FProject.Timeline;
  for ti := 0 to tl.TrackCount - 1 do
  begin
    trk := tl.GetTrack(ti);
    SetLength(ids, trk.ClipCount);
    for j := 0 to trk.ClipCount - 1 do
      ids[j] := trk.GetClip(j).Id;
    for id in ids do
    begin
      c := tl.ClipById(id);
      if (c <> nil) and (FTlRangeStartSec > c.StartSeconds + TIMELINE_MIN_CLIP_SECONDS) and
         (FTlRangeStartSec < c.EndSeconds - TIMELINE_MIN_CLIP_SECONDS) then
        FCmds.Perform(TSplitTimelineClipCommand.Create(FProject, id, FTlRangeStartSec));
      c := tl.ClipById(id);
      if (c <> nil) and (FTlRangeEndSec > c.StartSeconds + TIMELINE_MIN_CLIP_SECONDS) and
         (FTlRangeEndSec < c.EndSeconds - TIMELINE_MIN_CLIP_SECONDS) then
        FCmds.Perform(TSplitTimelineClipCommand.Create(FProject, id, FTlRangeEndSec));
    end;
  end;
end;

procedure TfrmMain.btnTlSplitRangeClick(Sender: TObject);
begin
  if (FProject = nil) or not FTlRangeActive then Exit;
  try
    TlSplitAtRangeEdges;
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'Split at Range Edges FAILED: ' + E.Message);
  end;
end;

{ Splits at both boundaries first (so a clip only partly inside the range
  keeps its outside portion), then removes whatever now lies fully inside
  the range - across every track, not just the selected clip(s). }
procedure TfrmMain.btnTlDeleteRangeClick(Sender: TObject);
var
  tl: TTimeline;
  ti, j: Integer;
  trk: TTimelineTrack;
  ids: TArray<Integer>;
  id: Integer;
  c: TTimelineClip;
begin
  if (FProject = nil) or not FTlRangeActive then Exit;
  try
    TlSplitAtRangeEdges;
    tl := FProject.Timeline;
    for ti := 0 to tl.TrackCount - 1 do
    begin
      trk := tl.GetTrack(ti);
      SetLength(ids, trk.ClipCount);
      for j := 0 to trk.ClipCount - 1 do
        ids[j] := trk.GetClip(j).Id;
      for id in ids do
      begin
        c := tl.ClipById(id);
        if (c <> nil) and (c.StartSeconds >= FTlRangeStartSec - TIMELINE_MIN_CLIP_SECONDS) and
           (c.EndSeconds <= FTlRangeEndSec + TIMELINE_MIN_CLIP_SECONDS) then
          FCmds.Perform(TRemoveTimelineClipCommand.Create(FProject, id));
      end;
    end;
    FTlSelClipId := -1;
    SetLength(FTlSelClipIds, 0);
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'Delete Range FAILED: ' + E.Message);
  end;
end;

{ Fade In/Out Range: a clip-level volume ramp - the mixer-adjacent gain
  automation UDAW actually has - applied to whatever the range boundary
  overlaps on the currently active/selected Timeline track only
  (FTlSelectedTrackId), mirroring the classic "drag a time selection over a
  crossfade point, hit fade" workflow. Fade In Range covers a clip whose
  START falls inside the range (ramps from silence up to full volume across
  however much of the range covers its head); Fade Out Range covers a clip
  whose END falls inside the range (ramps down across however much of the
  range covers its tail). Both use the existing per-clip
  TSetTimelineClipFadeCommand - no new command needed, and neither one cuts
  the clip - it stays a single clip, only its fade length changes. }
procedure TfrmMain.btnTlFadeInRangeClick(Sender: TObject);
var
  tl: TTimeline;
  trk: TTimelineTrack;
  j: Integer;
  c: TTimelineClip;
  newFade: Double;
  tid: Integer;
begin
  if (FProject = nil) or not FTlRangeActive then Exit;
  try
    tl := FProject.Timeline;
    for tid in TlRangeTrackIds do
    begin
    trk := tl.TrackById(tid);
    if trk = nil then Continue;
    for j := 0 to trk.ClipCount - 1 do
    begin
      c := trk.GetClip(j);
      if (c.StartSeconds >= FTlRangeStartSec - TIMELINE_MIN_CLIP_SECONDS) and
         (c.StartSeconds < FTlRangeEndSec) then
      begin
        newFade := EnsureRange(FTlRangeEndSec - c.StartSeconds, 0, c.LengthSeconds);
        FCmds.Perform(TSetTimelineClipFadeCommand.Create(FProject, c.Id, ceStart, newFade));
        if newFade > 0 then
          c.AddEffectRegion('Fade In', 0, newFade, TlEffectColor('Fade In'));
      end;
    end;
    end;
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'Fade In Range FAILED: ' + E.Message);
  end;
end;

procedure TfrmMain.btnTlFadeOutRangeClick(Sender: TObject);
var
  tl: TTimeline;
  trk: TTimelineTrack;
  j: Integer;
  c: TTimelineClip;
  newFade: Double;
  tid: Integer;
begin
  if (FProject = nil) or not FTlRangeActive then Exit;
  try
    tl := FProject.Timeline;
    for tid in TlRangeTrackIds do
    begin
    trk := tl.TrackById(tid);
    if trk = nil then Continue;
    for j := 0 to trk.ClipCount - 1 do
    begin
      c := trk.GetClip(j);
      if (c.EndSeconds > FTlRangeStartSec) and
         (c.EndSeconds <= FTlRangeEndSec + TIMELINE_MIN_CLIP_SECONDS) then
      begin
        newFade := EnsureRange(c.EndSeconds - FTlRangeStartSec, 0, c.LengthSeconds);
        FCmds.Perform(TSetTimelineClipFadeCommand.Create(FProject, c.Id, ceEnd, newFade));
        if newFade > 0 then
          c.AddEffectRegion('Fade Out', c.LengthSeconds - newFade, newFade, TlEffectColor('Fade Out'));
      end;
    end;
    end;
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'Fade Out Range FAILED: ' + E.Message);
  end;
end;

procedure TfrmMain.btnTlLoopToRangeClick(Sender: TObject);
begin
  if (FProject = nil) or not FTlRangeActive then Exit;
  FProject.Timeline.LoopStartSeconds := FTlRangeStartSec;
  FProject.Timeline.LoopLengthSeconds := FTlRangeEndSec - FTlRangeStartSec;
  RefreshTimelineTab;
end;

{ Peak-normalizes every clip that overlaps the active range, on the currently
  active/selected Timeline track only (FTlSelectedTrackId), to -0.3 dBFS -
  purely a TSetTimelineClipGainCommand nudge (GainDb), so unlike the DSP
  effects below this never touches source audio at all, and it never cuts a
  clip either. }
procedure TfrmMain.btnTlNormalizeRangeClick(Sender: TObject);
const
  TARGET_DB = -0.3;
var
  tl: TTimeline;
  trk: TTimelineTrack;
  j: Integer;
  c: TTimelineClip;
  src: TMediaSource;
  player: TTimelinePlayer;
  dec: TDecodedSource;
  sr, ch, i, startFrame, frameCount, f: Integer;
  peak, v, newGainDb: Double;
  count, tid, clipNo, clipTotal: Integer;
begin
  if (FProject = nil) or not FTlRangeActive then Exit;
  count := 0;
  clipNo := 0;
  try
    tl := FProject.Timeline;
    player := TTimelinePlayer.Create(tl);
    try
      player.EnsureSourcesLoaded;
      clipTotal := 0;
      for tid in TlRangeTrackIds do
      begin
        trk := tl.TrackById(tid);
        if trk = nil then Continue;
        for j := 0 to trk.ClipCount - 1 do
        begin
          c := trk.GetClip(j);
          if (not c.Locked) and (c.EndSeconds > FTlRangeStartSec) and (c.StartSeconds < FTlRangeEndSec) then
            Inc(clipTotal);
        end;
      end;
      if clipTotal > 0 then FxBegin('Normalize', clipTotal, 2, memTimeline);   // scan peak / apply gain
      for tid in TlRangeTrackIds do
      begin
      trk := tl.TrackById(tid);
      if trk = nil then Continue;
      for j := 0 to trk.ClipCount - 1 do
      begin
        c := trk.GetClip(j);
        if c.Locked then Continue;
        if (c.EndSeconds <= FTlRangeStartSec) or (c.StartSeconds >= FTlRangeEndSec) then Continue;
        src := tl.SourceById(c.SourceId);
        if src = nil then Continue;
        Inc(clipNo);
        FxItem(clipNo);
        FxStage(1, 'scanning peak level', 0);
        dec := player.GetDecodedSource(src.Id);
        if (dec = nil) or dec.Failed or (dec.FrameCount = 0) then Continue;
        sr := dec.SampleRate;
        ch := dec.Channels;
        if (sr <= 0) or (ch <= 0) then Continue;
        startFrame := Round(c.SourceOffsetSeconds * sr);
        if startFrame < 0 then startFrame := 0;
        frameCount := Round(c.LengthSeconds * sr);
        if startFrame + frameCount > dec.FrameCount then
          frameCount := dec.FrameCount - startFrame;
        if frameCount <= 0 then Continue;

        peak := 0;
        for i := 0 to ch - 1 do
          for f := startFrame to startFrame + frameCount - 1 do
          begin
            v := Abs(dec.Data[i][f]);
            if v > peak then peak := v;
          end;
        FxStageDone(1, 'scan peak');
        if peak <= 1.0E-6 then Continue;
        FxStage(2, 'applying gain', 0);

        newGainDb := TARGET_DB - LinearToDb(peak);
        FCmds.Perform(TSetTimelineClipGainCommand.Create(FProject, c.Id, newGainDb));
        Inc(count);
        FxStageDone(2, 'gain applied');
      end;
      end;
    finally
      player.Free;
    end;
    FxEnd;
    if count = 0 then
      memTimeline.Lines.Insert(0, 'Normalize Selection: no eligible clips in the selected range.')
    else
      memTimeline.Lines.Insert(0, Format('Normalize Selection: %d clip(s) normalized to %.1f dBFS.', [count, TARGET_DB]));
    RefreshTimelineTab;
  except
    on E: Exception do
    begin
      FxEnd;
      memTimeline.Lines.Insert(0, 'Normalize Selection FAILED at clip ' + IntToStr(clipNo) + ': ' + E.Message);
    end;
  end;
end;

{ Toggles Reversed on every clip that overlaps the active range, on the
  currently active/selected Timeline track only (FTlSelectedTrackId) - a plain
  metadata flip (TTimelineClip.Reversed already drives playback direction via
  SourceSecondsAt), so no rendering is needed and no clip is cut. }
{ "Clip Tempo (BPM)..." - sets TTimelineClip.SourceBPM on the selected clip(s):
  the tempo the audio was made at (typed, or detected with "auto"). Play and
  every export then time-stretch it (pitch preserved) to the project/Timeline
  BPM, so the clip plays at that tempo whatever the file's own speed. 0 turns
  it off. Takes effect on the next Play/export. }
procedure TfrmMain.TlClipTempoClick(Sender: TObject);
var
  ids: TArray<Integer>;
  i, changed: Integer;
  c: TTimelineClip;
  player: TTimelinePlayer;
  dec: TDecodedSource;
  txt: string;
  bpm, oldLen, oldBpm: Double;
  auto: Boolean;
begin
  if FProject = nil then Exit;
  if FTlPlaying or FGraphPlaying or FWavPlaying or FTrkPlaying then
  begin
    memTimeline.Lines.Insert(0, 'Clip Tempo: stop playback first.');
    MessageDlg('Clip Tempo cannot be changed during playback. Stop playback first.',
      mtWarning, [mbOK], 0);
    Exit;
  end;
  SetLength(ids, 0);
  if FProject.Timeline.ClipById(FTlSelClipId) <> nil then
    ids := [FTlSelClipId];
  for i := 0 to High(FTlSelClipIds) do
    if FProject.Timeline.ClipById(FTlSelClipIds[i]) <> nil then
      ids := ids + [FTlSelClipIds[i]];
  { Clip Tempo is per channel: every audio clip on the channel(s) of the
    selected clip(s) - or on the selected channel when no clip is selected -
    gets the tempo, otherwise the other clips on it export at their native
    speed. }
  begin
    var chanIds: TArray<Integer>;
    var trk: TTimelineTrack;
    var k, j: Integer;
    var found: Boolean;
    SetLength(chanIds, 0);
    for i := 0 to High(ids) do
    begin
      if (FProject.Timeline.ClipById(ids[i], trk) <> nil) and (trk <> nil) then chanIds := chanIds + [trk.Id];
    end;
    if (Length(chanIds) = 0) and (FTlSelectedTrackId >= 0) then
      chanIds := [FTlSelectedTrackId];
    for i := 0 to High(chanIds) do
    begin
      trk := FProject.Timeline.TrackById(chanIds[i]);
      if trk = nil then Continue;
      for k := 0 to trk.ClipCount - 1 do
        if not trk.GetClip(k).IsMidiClip then
        begin
          found := False;
          for j := 0 to High(ids) do
            if ids[j] = trk.GetClip(k).Id then found := True;
          if not found then ids := ids + [trk.GetClip(k).Id];
        end;
    end;
  end;
  if Length(ids) = 0 then
  begin
    memTimeline.Lines.Insert(0, 'Clip Tempo: select a clip or channel first.');
    Exit;
  end;
  c := FProject.Timeline.ClipById(ids[0]);
  if c.SourceBPM > 0 then txt := FloatToStr(c.SourceBPM, TFormatSettings.Invariant)
  else txt := 'auto';
  if not PromptValueBelow('Clip Tempo',
    'Original tempo of the selected clip(s) in BPM. Type "auto" to detect it from ' +
    'the audio, or 0 to play the clip at its own speed:', txt) then Exit;
  txt := Trim(txt);
  auto := SameText(txt, 'auto');
  bpm := 0;
  if not auto then
  begin
    if not TryStrToFloat(txt, bpm, TFormatSettings.Invariant) or
       ((bpm <> 0) and ((bpm < 20) or (bpm > 400))) then
    begin
      MessageDlg('Enter "auto", 0, or a tempo between 20 and 400 BPM.', mtError, [mbOK], 0);
      Exit;
    end;
  end;

  changed := 0;
  player := nil;
  try
    if auto then
    begin
      player := TTimelinePlayer.Create(FProject.Timeline);
      ShowStatusProgress('Detecting clip tempo...', 100);
      try
        player.EnsureSourcesLoaded(
          procedure(AFraction: Double)
          begin
            UpdateStatusProgress(Round(AFraction * 100));
          end);
      finally
        HideStatusProgress;
      end;
    end;
    ShowStatusProgress('Applying clip tempo...', Length(ids));
    for i := 0 to High(ids) do
    begin
      UpdateStatusProgress(i);
      c := FProject.Timeline.ClipById(ids[i]);
      if (c = nil) or c.IsMidiClip then Continue;
      if auto then
      begin
        dec := player.GetDecodedSource(c.SourceId);
        if (dec = nil) or dec.Failed then Continue;
        if dec.Channels > 1 then
          bpm := EstimateTempoBPM(dec.Data[0], dec.Data[1], dec.FrameCount, dec.SampleRate)
        else
          bpm := EstimateTempoBPM(dec.Data[0], dec.Data[0], dec.FrameCount, dec.SampleRate);
        if bpm <= 0 then
        begin
          memTimeline.Lines.Insert(0, Format('Clip Tempo: could not detect a tempo for "%s" - type it in instead.', [c.Name]));
          Continue;
        end;
      end;
      oldLen := c.LengthSeconds;
      oldBpm := c.SourceBPM;
      FCmds.Perform(TSetTimelineClipSourceBpmCommand.Create(FProject, c.Id, bpm));
      Inc(changed);
      if bpm > 0 then
        memTimeline.Lines.Insert(0, Format(
          'Clip "%s": source tempo %.2f BPM (was %.2f) -> conformed to project %.2f BPM, ' +
          'stretch factor %.4f (pitch kept). Length %.3f s -> %.3f s. Applied on Play/Export.',
          [c.Name, bpm, oldBpm, FProject.TempoBPM, bpm / FProject.TempoBPM, oldLen, c.LengthSeconds]))
      else
        memTimeline.Lines.Insert(0, Format('Clip "%s": tempo matching off. Length %.3f s -> %.3f s.',
          [c.Name, oldLen, c.LengthSeconds]));
    end;
  finally
    player.Free;
    HideStatusProgress;
  end;
  if changed > 0 then
  begin
    memTimeline.Lines.Insert(0, Format('Clip Tempo: %d clip(s) updated. New timeline total %.3f s.',
      [changed, FProject.Timeline.TotalDurationSeconds]));
    RefreshTimelineTab;
  end;
end;

procedure TfrmMain.btnTlReverseRangeClick(Sender: TObject);
var
  tl: TTimeline;
  trk: TTimelineTrack;
  j: Integer;
  c: TTimelineClip;
  count: Integer;
  tid, clipNo, clipTotal: Integer;
begin
  if (FProject = nil) or not FTlRangeActive then Exit;
  count := 0;
  clipNo := 0;
  try
    tl := FProject.Timeline;
    clipTotal := 0;
    for tid in TlRangeTrackIds do
    begin
      trk := tl.TrackById(tid);
      if trk = nil then Continue;
      for j := 0 to trk.ClipCount - 1 do
      begin
        c := trk.GetClip(j);
        if (not c.Locked) and (c.EndSeconds > FTlRangeStartSec) and (c.StartSeconds < FTlRangeEndSec) then
          Inc(clipTotal);
      end;
    end;
    if clipTotal > 0 then FxBegin('Reverse', clipTotal, 1, memTimeline);
    for tid in TlRangeTrackIds do
    begin
    trk := tl.TrackById(tid);
    if trk = nil then Continue;
    for j := 0 to trk.ClipCount - 1 do
    begin
      c := trk.GetClip(j);
      if c.Locked then Continue;
      if (c.EndSeconds <= FTlRangeStartSec) or (c.StartSeconds >= FTlRangeEndSec) then Continue;
      Inc(clipNo);
      FxItem(clipNo);
      FxStage(1, 'reversing clip', 0);
      FCmds.Perform(TSetTimelineClipReversedCommand.Create(FProject, c.Id, not c.Reversed));
      Inc(count);
      FxStageDone(1, 'clip reversed');
    end;
    end;
    FxEnd;
    if count = 0 then
      memTimeline.Lines.Insert(0, 'Reverse Selection: no eligible clips in the selected range.')
    else
      memTimeline.Lines.Insert(0, Format('Reverse Selection: %d clip(s) reversed.', [count]));
    RefreshTimelineTab;
  except
    on E: Exception do
    begin
      FxEnd;
      memTimeline.Lines.Insert(0, 'Reverse Selection FAILED: ' + E.Message);
    end;
  end;
end;

{ Offline "apply effect to selection": for every unlocked clip on the
  currently active/selected Timeline track (FTlSelectedTrackId) that overlaps
  the active ruler-drag range, the clip's own source window is decoded and
  copied through unchanged, then only the slice that actually lines up with
  the marked range is rendered through one AKind/AParams DSP node (the same
  node kinds and preset strings the Mixer tab's insert palette uses - see
  cboMixInsertKind/btnMixAddEQClick) and spliced back in - mirroring exactly
  how TlApplySilenceToRange treats the range (no TlSplitAtRangeEdges call, a
  clip stays a single clip, nothing is cut, only the marked slice changes, and
  only the selected track is touched). The result is saved as a new WAV file
  registered as a new TMediaSource; TSetTimelineClipSourceCommand then
  repoints the clip at it, so the render is a normal undoable edit even
  though the DSP work itself happens once, up front, outside the undo stack. }
procedure TfrmMain.TlApplyEffectToRange(const AKind, AParams, AEffectName: string);
const
  BLOCK = 1024;
var
  tl: TTimeline;
  trk: TTimelineTrack;
  ids, tids: TArray<Integer>;
  tid: Integer;
  j, id, count: Integer;
  c: TTimelineClip;
  src, newSrc: TMediaSource;
  player: TTimelinePlayer;
  dec: TDecodedSource;
  nodeKind: TNodeKind;
  node: TAudioNode;
  sr, ch, i, startFrame, frameCount, done, n: Integer;
  inBuf, outBuf: TAudioBuffer;
  outPlanar, fxIn, fxOut: TAudioPlanar;
  overlapStartSec, overlapEndSec: Double;
  fxFromFrame, fxToFrame, fxLen: Integer;
  gainRamp: Single;
  dir, fileName: string;
  stagesPerClip, totalStages, doneStages, clipNo, clipTotal: Integer;
  skipped: Integer;

  { Overall bar = completed stages + fraction of the current one (each stage
    is worth 100 ticks), so the user sees every stage of every clip advance. }
  procedure Stage(AStageNo: Integer; const AStageName: string; APct: Integer);
  begin
    UpdateStatusProgress(doneStages * 100 + APct,
      Format('%s - clip %d/%d - stage %d/%d: %s (%d%%)  [overall %d/%d stages]',
        [AEffectName, clipNo, clipTotal, AStageNo, stagesPerClip, AStageName, APct,
         doneStages, totalStages]));
  end;

  procedure StageDone(AStageNo: Integer; const AStageName: string);
  begin
    Inc(doneStages);
    Stage(AStageNo, AStageName + ' done', 100);
    memTimeline.Lines.Insert(0, Format('  %s  clip %d/%d  stage %d/%d  %s - done',
      [AEffectName, clipNo, clipTotal, AStageNo, stagesPerClip, AStageName]));
    Application.ProcessMessages;
  end;

begin
  if (FProject = nil) or not FTlRangeActive then Exit;
  { '@fadein' / '@fadeout' are not DSP nodes: they ramp the level over the range }
  if (Copy(AKind, 1, 1) <> '@') and
     not NodeKindFromId(AKind, nodeKind) then Exit;
  count := 0;
  clipNo := 0;
  clipTotal := 0;
  doneStages := 0;
  totalStages := 0;
  try
    tl := FProject.Timeline;
    tids := TlRangeTrackIds;
    if Length(tids) = 0 then Exit;
    player := TTimelinePlayer.Create(tl);
    try
      player.EnsureSourcesLoaded;
      { every selected channel, first to last: collect its clips, process them,
        then move on to the next selected channel }
      ids := nil;
      for tid in tids do
      begin
        trk := tl.TrackById(tid);
        if trk = nil then Continue;
        for j := 0 to trk.ClipCount - 1 do ids := ids + [trk.GetClip(j).Id];
      end;
      { pre-pass: only clips that will really be processed count as stages, so
        the totals shown are exact }
      stagesPerClip := 4;   // 1 read source  2 apply effect  3 write file  4 commit to timeline
      skipped := 0;
      clipTotal := 0;
      for id in ids do
      begin
        c := tl.ClipById(id);
        if (c = nil) or c.Locked or
           (Min(c.EndSeconds, FTlRangeEndSec) - Max(c.StartSeconds, FTlRangeStartSec)
             <= TIMELINE_MIN_CLIP_SECONDS) or (tl.SourceById(c.SourceId) = nil) then
          Inc(skipped)
        else
          Inc(clipTotal);
      end;
      totalStages := clipTotal * stagesPerClip;
      doneStages := 0;
      clipNo := 0;
      if totalStages > 0 then
      begin
        ShowStatusProgress(AEffectName + ' - starting...', totalStages * 100);
        memTimeline.Lines.Insert(0, Format('%s: %d clip(s) x %d stages = %d stages total (%d skipped)',
          [AEffectName, clipTotal, stagesPerClip, totalStages, skipped]));
        Application.ProcessMessages;
      end;
      for id in ids do
      begin
        c := tl.ClipById(id);
        if (c = nil) or c.Locked then Continue;
        { only clips that actually overlap the marked range need touching }
        overlapStartSec := Max(c.StartSeconds, FTlRangeStartSec);
        overlapEndSec := Min(c.EndSeconds, FTlRangeEndSec);
        if overlapEndSec - overlapStartSec <= TIMELINE_MIN_CLIP_SECONDS then Continue;
        src := tl.SourceById(c.SourceId);
        if src = nil then Continue;
        Inc(clipNo);
        doneStages := (clipNo - 1) * stagesPerClip;   // self-corrects if an earlier clip bailed out early
        Stage(1, 'reading source', 0);
        dec := player.GetDecodedSource(src.Id);
        if (dec = nil) or dec.Failed or (dec.FrameCount = 0) then Continue;

        sr := dec.SampleRate;
        ch := dec.Channels;
        if (sr <= 0) or (ch <= 0) then Continue;
        startFrame := Round(c.SourceOffsetSeconds * sr);
        if startFrame < 0 then startFrame := 0;
        frameCount := Round(c.LengthSeconds * sr);
        if startFrame + frameCount > dec.FrameCount then
          frameCount := dec.FrameCount - startFrame;
        if frameCount <= 0 then Continue;

        { copy the clip's existing window through unchanged, then render only
          the slice that lines up with the marked range through the DSP node }
        EnsurePlanar(outPlanar, ch, frameCount);
        for i := 0 to ch - 1 do
          Move(dec.Data[i][startFrame], outPlanar[i][0], frameCount * SizeOf(Single));

        fxFromFrame := Round((overlapStartSec - c.StartSeconds) * sr);
        fxToFrame := Round((overlapEndSec - c.StartSeconds) * sr);
        if fxFromFrame < 0 then fxFromFrame := 0;
        if fxToFrame > frameCount then fxToFrame := frameCount;
        fxLen := fxToFrame - fxFromFrame;
        if fxLen <= 0 then
        begin
          { keep the totals honest for a clip that turned out to have nothing to do }
          Inc(doneStages, stagesPerClip);
          Continue;
        end;
        StageDone(1, 'read source');
        Stage(2, 'applying ' + AEffectName, 0);

        if (AKind = '@fadein') or (AKind = '@fadeout') then
        begin
          { linear ramp across the selection: 0 -> 1 (in) or 1 -> 0 (out); the
            audio before/after the selection is left untouched }
          for i := 0 to ch - 1 do
            for n := 0 to fxLen - 1 do
            begin
              if fxLen > 1 then gainRamp := n / (fxLen - 1) else gainRamp := 1;
              if AKind = '@fadeout' then gainRamp := 1 - gainRamp;
              outPlanar[i][fxFromFrame + n] := outPlanar[i][fxFromFrame + n] * gainRamp;
            end;
        end
        else if IsSpectralKind(AKind) then
        begin
          { offline spectral tools (denoise / auto-tune / convolution): whole
            selection per channel, progress shown per channel }
          EnsurePlanar(fxIn, ch, fxLen);
          for i := 0 to ch - 1 do
            Move(outPlanar[i][fxFromFrame], fxIn[i][0], fxLen * SizeOf(Single));
          ApplySpectralFx(AKind, AParams, fxIn, ch, fxLen, sr, fxOut,
            procedure(AChan, AChans: Integer)
            begin
              UpdateStatusProgress(doneStages * 100 + Round(AChan / Max(AChans, 1) * 100),
                Format('%s - clip %d/%d - stage 2/%d: %s - channel %d/%d (spectral pass)  [overall %d/%d stages]',
                  [AEffectName, clipNo, clipTotal, stagesPerClip, AEffectName, AChan + 1, AChans,
                   doneStages, totalStages]));
              Application.ProcessMessages;
            end);
          for i := 0 to ch - 1 do
            Move(fxOut[i][0], outPlanar[i][fxFromFrame], fxLen * SizeOf(Single));
        end
        else
        begin
        node := CreateNode(1, nodeKind, AEffectName);
        try
          node.DeserializeParams(AParams);
          node.Configure(sr, BLOCK, ch);

          EnsurePlanar(fxIn, ch, fxLen);
          EnsurePlanar(fxOut, ch, fxLen);
          for i := 0 to ch - 1 do
            Move(outPlanar[i][fxFromFrame], fxIn[i][0], fxLen * SizeOf(Single));

          inBuf := TAudioBuffer.Create(ch, BLOCK, sr);
          outBuf := TAudioBuffer.Create(ch, BLOCK, sr);
          try
            done := 0;
            while done < fxLen do
            begin
              n := Min(BLOCK, fxLen - done);
              inBuf.SetActiveFrames(n);
              outBuf.SetActiveFrames(n);
              for i := 0 to ch - 1 do
                Move(fxIn[i][done], inBuf.ChannelPtr(i)^, n * SizeOf(Single));
              node.Process(inBuf, outBuf);
              for i := 0 to ch - 1 do
                Move(outBuf.ChannelPtr(i)^, fxOut[i][done], n * SizeOf(Single));
              Inc(done, n);
              if (done div BLOCK) mod 64 = 0 then
                Stage(2, 'applying ' + AEffectName, Round(done / fxLen * 100));
            end;
          finally
            inBuf.Free;
            outBuf.Free;
          end;

          for i := 0 to ch - 1 do
            Move(fxOut[i][0], outPlanar[i][fxFromFrame], fxLen * SizeOf(Single));
        finally
          node.Free;
        end;
        end;

        StageDone(2, 'apply ' + AEffectName);
        Stage(3, 'writing audio file', 0);
        dir := IncludeTrailingPathDelimiter(RecordingRootPath);
        ForceDirectories(dir);
        fileName := dir + Format('fx-%s-clip%d-%s.wav',
          [SafeSunoFileName(AEffectName), c.Id, FormatDateTime('yyyymmdd-hhnnsszzz', Now)]);
        SaveWavFile(fileName, outPlanar, ch, sr, frameCount, wsfPCM24);
        StageDone(3, 'write ' + ExtractFileName(fileName));
        Stage(4, 'updating timeline', 0);

        newSrc := tl.AddSource(fileName, sr, ch, frameCount);
        FCmds.Perform(TSetTimelineClipSourceCommand.Create(FProject, c.Id, newSrc.Id, 0));
        { colour + label the clip with the effect just rendered onto it, so
          pbTimelinePaint shows the assigned colour on the clip's own header
          strip and the effect's name right at the clip's start (region start
          point) - not a per-track annotation, a per-clip one, so it moves
          with the clip and scrolls with playback exactly like the clip does }
        c.EffectName := AEffectName;
        c.EffectOffsetSeconds := Max(0, overlapStartSec - c.StartSeconds);
        c.EffectLengthSeconds := overlapEndSec - overlapStartSec;
        c.Color := TlEffectColor(AEffectName);
        c.AddEffectRegion(AEffectName, c.EffectOffsetSeconds, c.EffectLengthSeconds, c.Color);
        Inc(count);
        StageDone(4, 'timeline updated');
      end;
    finally
      player.Free;
    end;
    if count = 0 then
      memTimeline.Lines.Insert(0, AEffectName + ': no eligible clips in the selected range.')
    else
    begin
      memTimeline.Lines.Insert(0, Format('%s applied to %d clip(s) - %d/%d stages complete.',
        [AEffectName, count, doneStages, totalStages]));
      for tid in tids do TlNoteEffectAdded(tid, AEffectName);
    end;
    RefreshTimelineTab;
    HideStatusProgress;
  except
    on E: Exception do
    begin
      HideStatusProgress;
      memTimeline.Lines.Insert(0, Format('%s FAILED at clip %d/%d after %d/%d stages: %s',
        [AEffectName, clipNo, clipTotal, doneStages, totalStages, E.Message]));
    end;
  end;
end;

{ "Silence": the one Timeline "Effects" entry that isn't a DSP graph node -
  it just means "mute this stretch of the clip". Unlike TlApplyEffectToRange
  it does NOT call TlSplitAtRangeEdges (a clip stays a single clip, nothing
  is cut into pieces), it only zeroes the samples that actually fall inside
  the marked range (the rest of the clip's audio is carried through
  untouched), and it only touches the currently active/selected Timeline
  track (FTlSelectedTrackId), not every track. }
procedure TfrmMain.TlApplySilenceToRange;
var
  tl: TTimeline;
  trk: TTimelineTrack;
  ids: TArray<Integer>;
  tid: Integer;
  j, id, count: Integer;
  c: TTimelineClip;
  src, newSrc: TMediaSource;
  player: TTimelinePlayer;
  dec: TDecodedSource;
  sr, ch, i, startFrame, frameCount: Integer;
  overlapStartSec, overlapEndSec: Double;
  zeroFromFrame, zeroToFrame: Integer;
  outPlanar: TAudioPlanar;
  dir, fileName: string;
  clipNo, clipTotal: Integer;
begin
  if (FProject = nil) or not FTlRangeActive then Exit;
  count := 0;
  clipNo := 0;
  try
    tl := FProject.Timeline;
    player := TTimelinePlayer.Create(tl);
    try
      player.EnsureSourcesLoaded;
      ids := nil;
      for tid in TlRangeTrackIds do
      begin
        trk := tl.TrackById(tid);
        if trk = nil then Continue;
        for j := 0 to trk.ClipCount - 1 do ids := ids + [trk.GetClip(j).Id];
      end;
      clipTotal := 0;
      for id in ids do
      begin
        c := tl.ClipById(id);
        if (c <> nil) and not c.Locked and (tl.SourceById(c.SourceId) <> nil) and
           (Min(c.EndSeconds, FTlRangeEndSec) - Max(c.StartSeconds, FTlRangeStartSec)
             > TIMELINE_MIN_CLIP_SECONDS) then
          Inc(clipTotal);
      end;
      if clipTotal > 0 then FxBegin('Silence', clipTotal, 4, memTimeline);   // read / silence / write / commit
      for id in ids do
      begin
        c := tl.ClipById(id);
        if (c = nil) or c.Locked then Continue;
        { only clips that actually overlap the marked range need touching }
        overlapStartSec := Max(c.StartSeconds, FTlRangeStartSec);
        overlapEndSec := Min(c.EndSeconds, FTlRangeEndSec);
        if overlapEndSec - overlapStartSec <= TIMELINE_MIN_CLIP_SECONDS then Continue;
        src := tl.SourceById(c.SourceId);
        if src = nil then Continue;
        Inc(clipNo);
        FxItem(clipNo);
        FxStage(1, 'reading source', 0);
        dec := player.GetDecodedSource(src.Id);
        if (dec = nil) or dec.Failed or (dec.FrameCount = 0) then Continue;

        sr := dec.SampleRate;
        ch := dec.Channels;
        if (sr <= 0) or (ch <= 0) then Continue;
        startFrame := Round(c.SourceOffsetSeconds * sr);
        if startFrame < 0 then startFrame := 0;
        frameCount := Round(c.LengthSeconds * sr);
        if startFrame + frameCount > dec.FrameCount then
          frameCount := dec.FrameCount - startFrame;
        if frameCount <= 0 then Continue;

        FxStageDone(1, 'read source');
        FxStage(2, 'silencing range', 0);
        { copy the clip's existing window through unchanged, then zero only
          the slice that lines up with the marked range }
        EnsurePlanar(outPlanar, ch, frameCount);
        for i := 0 to ch - 1 do
          Move(dec.Data[i][startFrame], outPlanar[i][0], frameCount * SizeOf(Single));

        zeroFromFrame := startFrame + Round((overlapStartSec - c.StartSeconds) * sr);
        zeroToFrame := startFrame + Round((overlapEndSec - c.StartSeconds) * sr);
        if zeroFromFrame < startFrame then zeroFromFrame := startFrame;
        if zeroToFrame > startFrame + frameCount then zeroToFrame := startFrame + frameCount;
        if zeroToFrame > zeroFromFrame then
          for i := 0 to ch - 1 do
            FillChar(outPlanar[i][zeroFromFrame - startFrame],
              (zeroToFrame - zeroFromFrame) * SizeOf(Single), 0);

        FxStageDone(2, 'silence range');
        FxStage(3, 'writing audio file', 0);
        dir := IncludeTrailingPathDelimiter(RecordingRootPath);
        ForceDirectories(dir);
        fileName := dir + Format('fx-Silence-clip%d-%s.wav',
          [c.Id, FormatDateTime('yyyymmdd-hhnnsszzz', Now)]);
        SaveWavFile(fileName, outPlanar, ch, sr, frameCount, wsfPCM24);
        FxStageDone(3, 'write ' + ExtractFileName(fileName));
        FxStage(4, 'updating timeline', 0);

        newSrc := tl.AddSource(fileName, sr, ch, frameCount);
        FCmds.Perform(TSetTimelineClipSourceCommand.Create(FProject, c.Id, newSrc.Id, 0));
        c.EffectName := 'Silence';
        c.EffectOffsetSeconds := Max(0, overlapStartSec - c.StartSeconds);
        c.EffectLengthSeconds := overlapEndSec - overlapStartSec;
        c.Color := TlEffectColor('Silence');
        c.AddEffectRegion('Silence', c.EffectOffsetSeconds, c.EffectLengthSeconds, c.Color);
        Inc(count);
        FxStageDone(4, 'timeline updated');
      end;
    finally
      player.Free;
    end;
    FxEnd;
    if count = 0 then
      memTimeline.Lines.Insert(0, 'Silence: no eligible clips in the selected range.')
    else
      memTimeline.Lines.Insert(0, Format('Silence applied to %d clip(s).', [count]));
    RefreshTimelineTab;
  except
    on E: Exception do
    begin
      FxEnd;
      memTimeline.Lines.Insert(0, 'Silence FAILED at clip ' + IntToStr(clipNo) + ': ' + E.Message);
    end;
  end;
end;

{ "Undo Effect" (Effects menu of the range right-click menu): for every
  selected channel, every clip overlapping the marked range gets its pre-effect
  audio (TTimelineClip.OrigSourceId/OrigDelta, recorded by the first rendered
  effect) spliced back over exactly that range, so the waveform is restored from
  the original file - the rest of the clip is untouched and nothing is cut.
  The effect references for the covered part are then removed (regions are
  trimmed/dropped; fades reset). The audio swap is one undoable command per
  clip. Only channels selected for the range are touched, as for applying. }
procedure TfrmMain.TlUndoEffectInRange;
var
  tl: TTimeline;
  trk: TTimelineTrack;
  ids: TArray<Integer>;
  tid, j, id, count, done, i: Integer;
  c: TTimelineClip;
  src, origSrc, newSrc: TMediaSource;
  player: TTimelinePlayer;
  dec, odec: TDecodedSource;
  sr, ch, startFrame, frameCount, fxFrom, fxTo, origStart: Integer;
  overlapStartSec, overlapEndSec, a, b, relS, relE: Double;
  outPlanar: TAudioPlanar;
  dir, fileName: string;
  regs, kept: TArray<TClipEffectRegion>;
  r, piece: TClipEffectRegion;
  touched: Boolean;
begin
  if (FProject = nil) or not FTlRangeActive then Exit;
  count := 0;
  done := 0;
  try
    tl := FProject.Timeline;
    ids := nil;
    for tid in TlRangeTrackIds do
    begin
      trk := tl.TrackById(tid);
      if trk = nil then Continue;
      for j := 0 to trk.ClipCount - 1 do ids := ids + [trk.GetClip(j).Id];
    end;
    if Length(ids) = 0 then Exit;
    ShowStatusProgress('Undo Effect - starting...', Length(ids) * 100);
    player := TTimelinePlayer.Create(tl);
    try
      player.EnsureSourcesLoaded;
      for id in ids do
      begin
        UpdateStatusProgress(done * 100, Format('Undo Effect - clip %d/%d', [done + 1, Length(ids)]));
        Inc(done);
        c := tl.ClipById(id);
        if (c = nil) or c.Locked then Continue;
        overlapStartSec := Max(c.StartSeconds, FTlRangeStartSec);
        overlapEndSec := Min(c.EndSeconds, FTlRangeEndSec);
        if overlapEndSec - overlapStartSec <= TIMELINE_MIN_CLIP_SECONDS then Continue;
        touched := False;

        { 1. restore the original waveform over the range }
        src := tl.SourceById(c.SourceId);
        origSrc := nil;
        if c.HasOrig then origSrc := tl.SourceById(c.OrigSourceId);
        if (src <> nil) and (origSrc <> nil) and (origSrc.Id <> src.Id) then
        begin
          dec := player.GetDecodedSource(src.Id);
          odec := player.GetDecodedSource(origSrc.Id);
          if (dec <> nil) and (odec <> nil) and not dec.Failed and not odec.Failed and
             (dec.SampleRate = odec.SampleRate) and (dec.Channels = odec.Channels) then
          begin
            sr := dec.SampleRate;
            ch := dec.Channels;
            startFrame := Max(0, Round(c.SourceOffsetSeconds * sr));
            frameCount := Round(c.LengthSeconds * sr);
            if startFrame + frameCount > dec.FrameCount then
              frameCount := dec.FrameCount - startFrame;
            fxFrom := Max(0, Round((overlapStartSec - c.StartSeconds) * sr));
            fxTo := Min(frameCount, Round((overlapEndSec - c.StartSeconds) * sr));
            origStart := Round((c.SourceOffsetSeconds + c.OrigDelta) * sr);
            { clamp the spliced slice to what the original file really holds }
            if origStart + fxFrom < 0 then fxFrom := -origStart;
            if origStart + fxTo > odec.FrameCount then fxTo := odec.FrameCount - origStart;
            if (frameCount > 0) and (fxTo > fxFrom) then
            begin
              EnsurePlanar(outPlanar, ch, frameCount);
              for i := 0 to ch - 1 do
              begin
                Move(dec.Data[i][startFrame], outPlanar[i][0], frameCount * SizeOf(Single));
                Move(odec.Data[i][origStart + fxFrom], outPlanar[i][fxFrom],
                  (fxTo - fxFrom) * SizeOf(Single));
              end;
              dir := IncludeTrailingPathDelimiter(RecordingRootPath);
              ForceDirectories(dir);
              fileName := dir + Format('fx-restore-clip%d-%s.wav',
                [c.Id, FormatDateTime('yyyymmdd-hhnnsszzz', Now)]);
              SaveWavFile(fileName, outPlanar, ch, sr, frameCount, wsfPCM24);
              newSrc := tl.AddSource(fileName, sr, ch, frameCount);
              FCmds.Perform(TSetTimelineClipSourceCommand.Create(FProject, c.Id, newSrc.Id, 0));
              touched := True;
            end;
          end
          else
            memTimeline.Lines.Insert(0, Format('Undo Effect: clip %d - original audio unavailable or format differs.', [c.Id]));
        end;

        { 2. remove the effect references for the covered part }
        relS := overlapStartSec - c.StartSeconds;
        relE := overlapEndSec - c.StartSeconds;
        regs := TlClipRegions(c);
        kept := nil;
        for r in regs do
        begin
          a := r.OffsetSeconds;
          if r.LengthSeconds <= 0 then b := c.LengthSeconds else b := a + r.LengthSeconds;
          if (b <= relS) or (a >= relE) then
          begin
            kept := kept + [r];   // not touched by the range
            Continue;
          end;
          touched := True;
          if SameText(r.Name, 'Fade In') and (a >= relS - TIMELINE_MIN_CLIP_SECONDS) then
            FCmds.Perform(TSetTimelineClipFadeCommand.Create(FProject, c.Id, ceStart, 0));
          if SameText(r.Name, 'Fade Out') and (b <= relE + TIMELINE_MIN_CLIP_SECONDS) then
            FCmds.Perform(TSetTimelineClipFadeCommand.Create(FProject, c.Id, ceEnd, 0));
          if a < relS - TIMELINE_MIN_CLIP_SECONDS then     // part left of the range stays
          begin
            piece := r;
            piece.LengthSeconds := relS - a;
            kept := kept + [piece];
          end;
          if b > relE + TIMELINE_MIN_CLIP_SECONDS then     // part right of the range stays
          begin
            piece := r;
            piece.OffsetSeconds := relE;
            piece.LengthSeconds := b - relE;
            kept := kept + [piece];
          end;
        end;
        if touched then
        begin
          c.EffectRegions := kept;
          if Length(kept) = 0 then
          begin
            c.EffectName := '';
            c.EffectOffsetSeconds := 0;
            c.EffectLengthSeconds := 0;
            c.Color := -1;
            c.HasOrig := False;   // fully back to the original sound
          end
          else
          begin
            c.EffectName := kept[High(kept)].Name;
            c.EffectOffsetSeconds := kept[High(kept)].OffsetSeconds;
            c.EffectLengthSeconds := kept[High(kept)].LengthSeconds;
            c.Color := kept[High(kept)].Color;
          end;
          Inc(count);
        end;
      end;
    finally
      player.Free;
    end;
    if count = 0 then
      memTimeline.Lines.Insert(0, 'Undo Effect: no effect found in the selected range.')
    else
      memTimeline.Lines.Insert(0, Format('Undo Effect: original sound restored on %d clip(s).', [count]));
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'Undo Effect FAILED: ' + E.Message);
  end;
  HideStatusProgress;
end;

{ A rendered effect lives in a WAV under the recordings/cache folder. When that
  file is missing (deleted cache, moved project) the clip can't play or export,
  so: the effect's title is flagged "??? <name>" (persisted in the region name),
  and - when the pre-effect original is still on disk - the clip is pointed
  straight back at the original (offset mapped through OrigDelta) so overall
  playback stays intact. Applied directly, not as an undo step: it repairs the
  project rather than editing it. Returns True when anything changed. }
function TfrmMain.TlHealMissingEffectSources: Boolean;
const
  MISSING_MARK = '??? ';
var
  tl: TTimeline;
  trk: TTimelineTrack;
  c: TTimelineClip;
  src, origSrc: TMediaSource;
  ti, ci, ri: Integer;
  regs: TArray<TClipEffectRegion>;
  restored: Boolean;
begin
  Result := False;
  if FProject = nil then Exit;
  tl := FProject.Timeline;
  for ti := 0 to tl.TrackCount - 1 do
  begin
    trk := tl.GetTrack(ti);
    for ci := 0 to trk.ClipCount - 1 do
    begin
      c := trk.GetClip(ci);
      if Length(c.EffectRegions) = 0 then Continue;
      src := tl.SourceById(c.SourceId);
      if (src = nil) or (src.Kind = mkVideoFile) or (src.Path = '') or FileExists(src.Path) then
        Continue;
      restored := False;
      if c.HasOrig and not c.Locked then
      begin
        origSrc := tl.SourceById(c.OrigSourceId);
        if (origSrc <> nil) and (origSrc.Path <> '') and FileExists(origSrc.Path) then
        begin
          tl.SetClipSource(c.Id, origSrc.Id, Max(0, c.SourceOffsetSeconds + c.OrigDelta));
          c.HasOrig := False;
          restored := True;
        end;
      end;
      regs := Copy(c.EffectRegions);
      for ri := 0 to High(regs) do
        if Copy(regs[ri].Name, 1, Length(MISSING_MARK)) <> MISSING_MARK then
          regs[ri].Name := MISSING_MARK + regs[ri].Name;
      c.EffectRegions := regs;
      if restored then
        memTimeline.Lines.Insert(0, Format('Clip %d: effect file missing - original sound restored, effect marked ???.', [c.Id]))
      else
        memTimeline.Lines.Insert(0, Format('Clip %d: effect file missing and no original to restore - marked ???.', [c.Id]));
      Result := True;
    end;
  end;
  if Result then FProject.Touch;
end;

procedure TfrmMain.TlUndoEffectClick(Sender: TObject);
begin
  TlUndoEffectInRange;
end;

{ Shared OnClick for every mnuTlFx.../pmTlFx... item - Sender.Tag picks the
  node kind and the same preset param strings the Mixer tab's insert palette
  offers (see btnMixAddEQClick), so a Timeline "apply effect" and a Mixer
  insert of the same effect start from an identical default sound. Tag 11
  ("Silence") isn't a DSP node at all, so it's dispatched to
  TlApplySilenceToRange instead of the generic kind/params path. }
{ Split Stems: separates the selected clip's audio into drums / bass / vocals /
  other (classical DSP masking, see UDAW.DSP.Spectral) and adds each as its own
  new track through undoable commands. }
procedure TfrmMain.TlSplitStemsSelected;
var
  tl: TTimeline;
  c: TTimelineClip;
  src: TMediaSource;
  newSrc: TMediaSource;
  player: TTimelinePlayer;
  dec: TDecodedSource;
  planar: TAudioPlanar;
  sr, ch, i, startFrame, frameCount: Integer;
  base, fDrums, fBass, fVocals, fOther: string;
  files: array[0..3] of string;
  labels: array[0..3] of string;
  trackCmd: TAddTimelineTrackCommand;
begin
  if FProject = nil then Exit;
  tl := FProject.Timeline;
  c := tl.ClipById(FTlSelClipId);
  if c = nil then
  begin
    memTimeline.Lines.Insert(0, 'Split Stems: select a clip first.');
    Exit;
  end;
  try
    ShowStatusProgress('Split Stems - reading source...', 400);
    player := TTimelinePlayer.Create(tl);
    try
      player.EnsureSourcesLoaded;
      src := tl.SourceById(c.SourceId);
      if src = nil then Exit;
      dec := player.GetDecodedSource(src.Id);
      if (dec = nil) or dec.Failed or (dec.FrameCount = 0) then Exit;
      sr := dec.SampleRate;
      ch := dec.Channels;
      startFrame := Max(Round(c.SourceOffsetSeconds * sr), 0);
      frameCount := Min(Round(c.LengthSeconds * sr), dec.FrameCount - startFrame);
      if frameCount <= 0 then Exit;
      EnsurePlanar(planar, ch, frameCount);
      for i := 0 to ch - 1 do
        Move(dec.Data[i][startFrame], planar[i][0], frameCount * SizeOf(Single));
    finally
      player.Free;
    end;
    UpdateStatusProgress(100, 'Split Stems - separating (this can take a while)...');
    Application.ProcessMessages;
    ForceDirectories(IncludeTrailingPathDelimiter(RecordingRootPath));
    base := IncludeTrailingPathDelimiter(RecordingRootPath) +
      Format('stems-clip%d-%s', [c.Id, FormatDateTime('yyyymmdd-hhnnss', Now)]);
    if not SplitStemsToFiles(planar, ch, frameCount, sr, base, fDrums, fBass, fVocals, fOther) then
    begin
      HideStatusProgress;
      memTimeline.Lines.Insert(0, 'Split Stems: clip too short.');
      Exit;
    end;
    files[0] := fDrums; files[1] := fBass; files[2] := fVocals; files[3] := fOther;
    labels[0] := 'Drums'; labels[1] := 'Bass'; labels[2] := 'Vocals'; labels[3] := 'Other';
    for i := 0 to 3 do
    begin
      UpdateStatusProgress(200 + i * 50, 'Split Stems - adding track ' + labels[i]);
      newSrc := tl.AddSource(files[i], sr, 2, frameCount);
      trackCmd := TAddTimelineTrackCommand.Create(FProject, tkAudio, c.Name + ' - ' + labels[i]);
      FCmds.Perform(trackCmd);
      FCmds.Perform(TAddTimelineClipCommand.Create(FProject, trackCmd.CreatedId, newSrc.Id,
        c.Name + ' ' + labels[i], c.StartSeconds, 0, c.LengthSeconds));
    end;
    EnsureMixerStripsForTimelineTracks;
    memTimeline.Lines.Insert(0, 'Split Stems: 4 stem tracks added (drums, bass, vocals, other).');
    RefreshTimelineTab;
    HideStatusProgress;
  except
    on E: Exception do
    begin
      HideStatusProgress;
      memTimeline.Lines.Insert(0, 'Split Stems FAILED: ' + E.Message);
    end;
  end;
end;

{ Audio to MIDI: transcribes the selected clip into a new Piano Roll clip
  (mono = melody/bass line, poly = chords) via undoable commands. }
procedure TfrmMain.TlAudioToMidiSelected;
var
  tl: TTimeline;
  c: TTimelineClip;
  src: TMediaSource;
  player: TTimelinePlayer;
  dec: TDecodedSource;
  mono: TAudioSampleArray;
  notes: TSeqNotes;
  opts: TA2MOptions;
  modeText: string;
  sr, ch, i, k, startFrame, frameCount, clipIdx: Integer;
  ppq: Integer;
  v: Double;
begin
  if FProject = nil then Exit;
  tl := FProject.Timeline;
  c := tl.ClipById(FTlSelClipId);
  if c = nil then
  begin
    memTimeline.Lines.Insert(0, 'Audio to MIDI: select a clip first.');
    Exit;
  end;
  modeText := 'mono';
  if not PromptValueBelow('Audio to MIDI',
    'Transcription mode: "mono" (single melody / bass line) or "poly" (chords):', modeText) then Exit;
  try
    ShowStatusProgress('Audio to MIDI - reading source...', 300);
    player := TTimelinePlayer.Create(tl);
    try
      player.EnsureSourcesLoaded;
      src := tl.SourceById(c.SourceId);
      if src = nil then Exit;
      dec := player.GetDecodedSource(src.Id);
      if (dec = nil) or dec.Failed or (dec.FrameCount = 0) then Exit;
      sr := dec.SampleRate;
      ch := dec.Channels;
      startFrame := Max(Round(c.SourceOffsetSeconds * sr), 0);
      frameCount := Min(Round(c.LengthSeconds * sr), dec.FrameCount - startFrame);
      if frameCount <= 0 then Exit;
      SetLength(mono, frameCount);
      for i := 0 to frameCount - 1 do
      begin
        v := 0;
        for k := 0 to ch - 1 do v := v + dec.Data[k][startFrame + i];
        mono[i] := v / ch;
      end;
    finally
      player.Free;
    end;
    UpdateStatusProgress(100, 'Audio to MIDI - analysing pitch...');
    Application.ProcessMessages;
    opts := TA2MOptions.Default;
    opts.Bpm := FProject.TempoBPM;
    if SameText(Trim(modeText), 'poly') then opts.Mode := a2mPoly else opts.Mode := a2mMono;
    notes := AudioToMidi(mono, sr, opts);
    UpdateStatusProgress(200, Format('Audio to MIDI - writing %d notes...', [Length(notes)]));
    if Length(notes) = 0 then
    begin
      HideStatusProgress;
      memTimeline.Lines.Insert(0, 'Audio to MIDI: no notes detected (try poly mode or a louder clip).');
      Exit;
    end;
    ppq := MIDI_DEFAULT_PPQ;
    FCmds.Perform(TAddMidiClipCommand.Create(FProject, 'Transcribed ' + c.Name, ppq));
    clipIdx := FProject.Midi.ClipCount - 1;
    for i := 0 to High(notes) do
      FCmds.Perform(TAddMidiNoteCommand.Create(FProject, clipIdx, 0,
        Round(notes[i].Beat * ppq), Max(Round(notes[i].Length * ppq), 1),
        notes[i].Key, notes[i].Velocity, 0));
    FMidiClipIndex := clipIdx;
    FMidiTrackIndex := 0;
    RefreshMidiTab;
    memTimeline.Lines.Insert(0, Format('Audio to MIDI: %d notes written to a new Piano Roll clip.', [Length(notes)]));
    HideStatusProgress;
  except
    on E: Exception do
    begin
      HideStatusProgress;
      memTimeline.Lines.Insert(0, 'Audio to MIDI FAILED: ' + E.Message);
    end;
  end;
end;

{ Metronome checkbox: takes effect immediately on a running Timeline player,
  and is picked up at the start of every later Play. }
procedure TfrmMain.chkTlMetronomeClick(Sender: TObject);
begin
  if (FTlPlayer <> nil) and (FProject <> nil) then
    FTlPlayer.SetMetronome(chkTlMetronome.Checked, FProject.TempoBPM, 4, -12);
end;

{ Warp markers (see UDAW.Timeline.Warp). Markers live per selected clip for the
  session; "Apply" bakes them into a new source through the undoable
  source-swap command, so the original file is never touched and Undo restores
  the previous audio. Tags: 1 add at playhead, 2 snap to nearest beat,
  3 auto-detect, 4 apply, 5 clear. }
procedure TfrmMain.TlWarpMenuClick(Sender: TObject);
var
  tl: TTimeline;
  c: TTimelineClip;
  src: TMediaSource;
  newSrc: TMediaSource;
  player: TTimelinePlayer;
  dec: TDecodedSource;
  planar, warped: TAudioPlanar;
  mono: TAudioSampleArray;
  onsets: TArray<Double>;
  usable: TWarpMarkers;
  sr, ch, i, k, startFrame, frameCount, outFrames, idx: Integer;
  rel, spb, beatAbs, lenSec, v: Double;
  fileName: string;
begin
  if FProject = nil then Exit;
  tl := FProject.Timeline;
  c := tl.ClipById(FTlSelClipId);
  if (c = nil) or c.IsMidiClip then
  begin
    memTimeline.Lines.Insert(0, 'Warp: select an audio clip first.');
    Exit;
  end;
  if FWarpClipId <> c.Id then
  begin
    FWarpClipId := c.Id;
    SetLength(FWarpMarkers, 0);
  end;
  rel := tl.PlayheadSeconds - c.StartSeconds;
  spb := 60.0 / Max(FProject.TempoBPM, 20.0);
  case TMenuItem(Sender).Tag of
    1: begin
         if (rel <= WARP_MIN_SEGMENT_SEC) or (rel >= c.LengthSeconds - WARP_MIN_SEGMENT_SEC) then
         begin
           memTimeline.Lines.Insert(0, 'Warp: put the playhead inside the selected clip first.');
           Exit;
         end;
         AddWarpMarker(FWarpMarkers, rel, rel);
         memTimeline.Lines.Insert(0, Format('Warp: marker added at %.3f s (%d marker(s)).',
           [rel, Length(FWarpMarkers)]));
       end;
    2: begin
         idx := NearestWarpMarker(FWarpMarkers, rel, 0.3);
         if idx < 0 then
         begin
           if (rel <= WARP_MIN_SEGMENT_SEC) or (rel >= c.LengthSeconds - WARP_MIN_SEGMENT_SEC) then
           begin
             memTimeline.Lines.Insert(0, 'Warp: put the playhead on the audio event to pin first.');
             Exit;
           end;
           AddWarpMarker(FWarpMarkers, rel, rel);
           idx := NearestWarpMarker(FWarpMarkers, rel, 0.02);
         end;
         beatAbs := Round((c.StartSeconds + FWarpMarkers[idx].SrcSec) / spb) * spb;
         FWarpMarkers[idx].DstSec := beatAbs - c.StartSeconds;
         NormalizeWarpMarkers(FWarpMarkers);
         memTimeline.Lines.Insert(0, Format('Warp: marker snapped to the beat grid (%d marker(s)).',
           [Length(FWarpMarkers)]));
       end;
    3, 4:
       begin
         if FTlPlaying or FGraphPlaying or FWavPlaying or FTrkPlaying then
         begin
           memTimeline.Lines.Insert(0, 'Warp: stop playback first.');
           Exit;
         end;
         if (TMenuItem(Sender).Tag = 4) and (Length(FWarpMarkers) = 0) then
         begin
           memTimeline.Lines.Insert(0, 'Warp: no markers - add some or use Auto-Detect.');
           Exit;
         end;
         try
           ShowStatusProgress('Warp - reading source...', 300);
           player := TTimelinePlayer.Create(tl);
           try
             player.EnsureSourcesLoaded;
             src := tl.SourceById(c.SourceId);
             if src = nil then Exit;
             dec := player.GetDecodedSource(src.Id);
             if (dec = nil) or dec.Failed or (dec.FrameCount = 0) then Exit;
             sr := dec.SampleRate;
             ch := dec.Channels;
             startFrame := Max(Round(c.SourceOffsetSeconds * sr), 0);
             frameCount := Min(Round(c.LengthSeconds * sr), dec.FrameCount - startFrame);
             if frameCount < 4096 then Exit;
             EnsurePlanar(planar, ch, frameCount);
             for i := 0 to ch - 1 do
               Move(dec.Data[i][startFrame], planar[i][0], frameCount * SizeOf(Single));
           finally
             player.Free;
           end;
           lenSec := frameCount / sr;
           if TMenuItem(Sender).Tag = 3 then
           begin
             UpdateStatusProgress(100, 'Warp - detecting beats...');
             Application.ProcessMessages;
             SetLength(mono, frameCount);
             for i := 0 to frameCount - 1 do
             begin
               v := 0;
               for k := 0 to ch - 1 do v := v + planar[k][i];
               mono[i] := v / ch;
             end;
             onsets := DetectOnsets(mono, sr);
             FWarpMarkers := AutoWarpMarkers(onsets, FProject.TempoBPM, c.StartSeconds);
             memTimeline.Lines.Insert(0, Format('Warp: %d onset(s) found, %d pinned to the grid. ' +
               'Use "Warp: Apply Markers" to render.', [Length(onsets), Length(FWarpMarkers)]));
             HideStatusProgress;
             Exit;
           end;
           { keep only markers that leave room for the tail segment }
           SetLength(usable, 0);
           for i := 0 to High(FWarpMarkers) do
             if (FWarpMarkers[i].SrcSec < lenSec - WARP_MIN_SEGMENT_SEC) and
                (FWarpMarkers[i].DstSec < lenSec - WARP_MIN_SEGMENT_SEC) then
             begin
               SetLength(usable, Length(usable) + 1);
               usable[High(usable)] := FWarpMarkers[i];
             end;
           NormalizeWarpMarkers(usable);
           if Length(usable) = 0 then
           begin
             HideStatusProgress;
             memTimeline.Lines.Insert(0, 'Warp: no usable markers (too close together or too extreme).');
             Exit;
           end;
           UpdateStatusProgress(150, Format('Warp - stretching %d segment(s)...', [Length(usable) + 1]));
           Application.ProcessMessages;
           RenderWarp(planar, ch, frameCount, sr, usable, warped, outFrames);
           UpdateStatusProgress(250, 'Warp - writing audio file...');
           ForceDirectories(IncludeTrailingPathDelimiter(RecordingRootPath));
           fileName := IncludeTrailingPathDelimiter(RecordingRootPath) +
             Format('warp-clip%d-%s.wav', [c.Id, FormatDateTime('yyyymmdd-hhnnsszzz', Now)]);
           SaveWavFile(fileName, warped, ch, sr, Min(outFrames, frameCount), wsfPCM24);
           newSrc := tl.AddSource(fileName, sr, ch, Min(outFrames, frameCount));
           FCmds.Perform(TSetTimelineClipSourceCommand.Create(FProject, c.Id, newSrc.Id, 0));
           c.EffectName := 'Warp';
           c.Color := TlEffectColor('Warp');
           SetLength(FWarpMarkers, 0);
           memTimeline.Lines.Insert(0, Format('Warp applied: %d marker(s) rendered (undoable).', [Length(usable)]));
           RefreshTimelineTab;
           HideStatusProgress;
         except
           on E: Exception do
           begin
             HideStatusProgress;
             memTimeline.Lines.Insert(0, 'Warp FAILED: ' + E.Message);
           end;
         end;
       end;
    5: begin
         SetLength(FWarpMarkers, 0);
         memTimeline.Lines.Insert(0, 'Warp: markers cleared.');
       end;
  end;
end;

procedure TfrmMain.TlFxFadeInClick(Sender: TObject);
begin
  TlApplyEffectToRange('@fadein', '', 'Fade In');
end;

procedure TfrmMain.TlFxFadeOutClick(Sender: TObject);
begin
  TlApplyEffectToRange('@fadeout', '', 'Fade Out');
end;

procedure TfrmMain.TlFxMenuClick(Sender: TObject);
var
  kind, params, name, gainText: string;
  gainDb: Double;
begin
  if TMenuItem(Sender).Tag = 11 then
  begin
    TlApplySilenceToRange;
    Exit;
  end;
  case TMenuItem(Sender).Tag of
    1: begin kind := 'compressor'; params := 'type=compressor;thresh=-18;ratio=3;knee=6;attack=10;release=120;makeup=0'; name := 'Compressor'; end;
    2: begin kind := 'reverb';     params := 'size=0.7;damp=0.4;width=1;mix=0.3;predelay=15'; name := 'Reverb'; end;
    3: begin kind := 'modulation'; params := 'type=chorus;rate=0.6;depth=0.6;mix=0.4;stereo=90'; name := 'Chorus'; end;
    4: begin kind := 'modulation'; params := 'type=flanger;rate=0.25;depth=0.7;mix=0.5;fb=0.4;stereo=90'; name := 'Flanger'; end;
    5: begin kind := 'modulation'; params := 'type=phaser;rate=0.4;depth=0.8;mix=0.5;fb=0.3;stages=6;stereo=90'; name := 'Phaser'; end;
    6: begin kind := 'modulation'; params := 'type=tremolo;rate=4;depth=0.6;mix=1'; name := 'Tremolo'; end;
    7: begin kind := 'modulation'; params := 'type=autopan;rate=0.5;depth=1;mix=1'; name := 'Auto-Pan'; end;
    8: begin kind := 'distortion'; params := 'type=saturation;drive=3;trim=0;mix=1'; name := 'Saturation'; end;
    9: begin kind := 'distortion'; params := 'type=bitcrush;bits=8;down=4;mix=1'; name := 'Bit Crusher'; end;
    10: begin kind := 'graphiceq'; params := 'bands=10;gains=0,0,1,2,3,3,2,1,0,0'; name := 'Brighten EQ'; end;
    12: begin
          { Amplify: plain gain in dB, positive to boost and negative to cut }
          gainText := '6';
          if not PromptValueBelow('Amplify',
            'Gain in dB to apply to the selection (negative values reduce the level):',
            gainText) then Exit;
          if not TryStrToFloat(Trim(gainText), gainDb, TFormatSettings.Invariant) then
            if not TryStrToFloat(Trim(gainText), gainDb) then Exit;
          kind := 'gain';
          params := 'db=' + FloatToStr(EnsureRange(gainDb, -60, 60), TFormatSettings.Invariant);
          name := 'Amplify';
        end;
    13: begin kind := 'compressor'; params := 'type=deesser;thresh=-24;ratio=4;knee=3;attack=1;release=80;makeup=0'; name := 'De-Esser'; end;
    14: begin kind := 'delay';      params := 'ms=250;fb=0.3;mix=0.3;pingpong=0'; name := 'Delay'; end;
    15: begin kind := 'compressor'; params := 'type=expander;thresh=-30;ratio=2;knee=6;attack=5;release=100;makeup=0'; name := 'Expander'; end;
    16: begin kind := 'distortion'; params := 'type=foldback;drive=3;trim=0;mix=1'; name := 'Foldback'; end;
    17: begin kind := 'compressor'; params := 'type=gate;thresh=-40;ratio=6;knee=2;attack=1;release=60;makeup=0;hold=15;range=-60'; name := 'Gate'; end;
    18: begin kind := 'distortion'; params := 'type=hardclip;drive=3;trim=0;mix=1'; name := 'Hard Clip'; end;
    19: begin kind := 'lookaheadlimiter'; params := 'ceiling=-0.3;release=100;lookahead=5'; name := 'Limiter'; end;
    20: begin kind := 'delay';      params := 'ms=250;fb=0.35;mix=0.35;pingpong=1'; name := 'Ping-Pong Delay'; end;
    21: begin
          { Balance: -100 = full left, 0 = centre, 100 = full right (constant-power pan law) }
          gainText := '0';
          if not PromptValueBelow('Balance',
            'Balance from -100 (left) to 100 (right); 0 is centre:', gainText) then Exit;
          if not TryStrToFloat(Trim(gainText), gainDb, TFormatSettings.Invariant) then
            if not TryStrToFloat(Trim(gainText), gainDb) then Exit;
          kind := 'pan';
          params := 'pos=' + FloatToStr(EnsureRange(gainDb, -100, 100) / 100, TFormatSettings.Invariant);
          name := 'Balance';
        end;
    22: begin kind := 'biquad'; params := 'type=lowshelf;freq=100;q=0.707;gaindb=6'; name := 'Bass Enhance'; end;
    23: begin kind := 'dcblock'; params := 'hz=20'; name := 'DC Offset Remover'; end;
    24: begin kind := 'exciter'; params := 'freq=3000;drive=4;mix=0.25'; name := 'Exciter'; end;
    25: begin kind := 'biquad'; params := 'type=highpass;freq=80;q=0.707;gaindb=0'; name := 'High-Pass Filter'; end;
    26: begin kind := 'biquad'; params := 'type=lowpass;freq=8000;q=0.707;gaindb=0'; name := 'Low-Pass Filter'; end;
    27: begin kind := 'stereowidth'; params := 'width=0'; name := 'Make Mono'; end;
    28: begin kind := 'multibandcomp'; params := ''; name := 'Multiband Compressor'; end;
    29: begin kind := 'biquad'; params := 'type=notch;freq=60;q=8;gaindb=0'; name := 'Notch Filter'; end;
    30: begin
          { Pitch Shift: semitones, positive up, negative down }
          gainText := '2';
          if not PromptValueBelow('Pitch Shift',
            'Semitones to shift the selection (negative values go down, e.g. -12 is one octave):',
            gainText) then Exit;
          if not TryStrToFloat(Trim(gainText), gainDb, TFormatSettings.Invariant) then
            if not TryStrToFloat(Trim(gainText), gainDb) then Exit;
          kind := 'pitchshift';
          params := 'semitones=' + FloatToStr(EnsureRange(gainDb, -24, 24), TFormatSettings.Invariant);
          name := 'Pitch Shift';
        end;
    31: begin kind := 'biquad'; params := 'type=peaking;freq=3000;q=1;gaindb=4'; name := 'Presence Boost'; end;
    32: begin kind := 'stereowidth'; params := 'width=1.5'; name := 'Stereo Widener'; end;
    33: begin kind := 'transientshaper'; params := 'attack=6;sustain=0'; name := 'Transient Shaper'; end;
    34: begin kind := 'biquad'; params := 'type=highshelf;freq=8000;q=0.707;gaindb=6'; name := 'Treble Boost'; end;
    35: begin
          gainText := '12';
          if not PromptValueBelow('Noise Reduction',
            'Reduction in dB (the first 0.4 s of the selection must be noise only - it is used as the noise profile):',
            gainText) then Exit;
          if not TryStrToFloat(Trim(gainText), gainDb, TFormatSettings.Invariant) then
            if not TryStrToFloat(Trim(gainText), gainDb) then Exit;
          kind := '@denoise';
          params := 'reduce=' + FloatToStr(EnsureRange(gainDb, 1, 40), TFormatSettings.Invariant);
          name := 'Noise Reduction';
        end;
    36: begin
          gainText := 'C major';
          if not PromptValueBelow('Auto-Tune',
            'Target scale (e.g. "C major", "A minor", "F# major", or "chromatic"):',
            gainText) then Exit;
          kind := '@autotune';
          params := 'scale=' + Trim(gainText) + ';strength=1';
          name := 'Auto-Tune';
        end;
    37: begin
          if not dlgOpenWav.Execute then Exit;
          kind := '@convolve';
          params := 'ir=' + dlgOpenWav.FileName + ';mix=0.3';
          name := 'Convolution Reverb';
        end;
    38: begin TlSplitStemsSelected; Exit; end;
    39: begin TlAudioToMidiSelected; Exit; end;
  else
    Exit;
  end;
  TlApplyEffectToRange(kind, params, name);
end;

{ Removes every selected clip - the multi-selection (FTlSelClipIds) as well as
  the primary (FTlSelClipId) - so a rubber-band/Ctrl-click selection of
  several clips deletes as one gesture, like any arrangement view. }
procedure TfrmMain.btnTlDeleteClipClick(Sender: TObject);
var
  i: Integer;
begin
  if (FProject = nil) or (FTlSelClipId < 0) then Exit;
  try
    for i := 0 to High(FTlSelClipIds) do
      FCmds.Perform(TRemoveTimelineClipCommand.Create(FProject, FTlSelClipIds[i]));
    FCmds.Perform(TRemoveTimelineClipCommand.Create(FProject, FTlSelClipId));
    TlSetSingleSelection(-1);
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'Remove element FAILED: ' + E.Message);
  end;
end;

{ Removes the whole track under the last click/right-click (FTlCtxTrackId,
  set in pbTimelineMouseDown) - as opposed to "Remove Element", which only
  removes the single clip at that position. }
procedure TfrmMain.btnTlRemoveTrackClick(Sender: TObject);
begin
  if (FProject = nil) or (FTlCtxTrackId < 0) then Exit;
  try
    FCmds.Perform(TRemoveTimelineTrackCommand.Create(FProject, FTlCtxTrackId));
    FTlSelClipId := -1;
    if FTlSelectedTrackId = FTlCtxTrackId then
      FTlSelectedTrackId := -1;
  FRecInsertSeconds := 0;
    FTlCtxTrackId := -1;
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'Remove timeline FAILED: ' + E.Message);
  end;
end;

procedure TfrmMain.BuildDemoArrangement;
const
  SR = 48000;

  procedure WriteTone(const AFileName: string; AFreq, ASeconds, AAmp: Double;
    ANoise: Boolean);
  var
    planar: TAudioPlanar;
    n, i: Integer;
    ph, env: Double;
    rnd: Cardinal;
  begin
    n := Round(SR * ASeconds);
    SetLength(planar, 2);
    SetLength(planar[0], n);
    SetLength(planar[1], n);
    rnd := 22222;
    for i := 0 to n - 1 do
    begin
      { simple AD envelope so each hit looks like a real transient }
      env := Exp(-3.0 * (i / SR) / ASeconds);
      if ANoise then
      begin
        rnd := rnd * 1664525 + 1013904223;
        ph := (Integer(rnd shr 8) / 8388608.0) - 1.0;
        planar[0][i] := AAmp * env * ph;
        planar[1][i] := AAmp * env * ph * 0.9;
      end
      else
      begin
        ph := 2 * Pi * AFreq * i / SR;
        planar[0][i] := AAmp * env * Sin(ph);
        planar[1][i] := AAmp * env * Sin(ph * 1.001);
      end;
    end;
    SaveWavFile(AFileName, planar, 2, SR, n, wsfFloat32);
  end;

var
  tl: TTimeline;
  dir, drumsFn, bassFn, leadFn: string;
  sDrums, sBass, sLead: TMediaSource;
  tDrums, tBass, tLead: TTimelineTrack;
  i: Integer;
begin
  if FProject = nil then Exit;
  dir := IncludeTrailingPathDelimiter(App.Paths.Cache);
  drumsFn := dir + 'udaw-demo-drums.wav';
  bassFn  := dir + 'udaw-demo-bass.wav';
  leadFn  := dir + 'udaw-demo-lead.wav';
  WriteTone(drumsFn, 0,     0.9, 0.8, True);
  WriteTone(bassFn,  55.0,  1.0, 0.7, False);
  WriteTone(leadFn,  440.0, 2.0, 0.5, False);

  tl := FProject.Timeline;
  tl.Clear;
  FTlSelClipId := -1;

  sDrums := tl.AddSource(drumsFn, SR, 2, Round(SR * 0.9));
  sBass  := tl.AddSource(bassFn,  SR, 2, Round(SR * 1.0));
  sLead  := tl.AddSource(leadFn,  SR, 2, Round(SR * 2.0));

  tDrums := tl.AddTrack(tkAudio, 'Drums');
  tBass  := tl.AddTrack(tkAudio, 'Bass');
  tLead  := tl.AddTrack(tkInstrument, 'Lead');

  { a 4-bar drum pattern: a hit on every beat (0.5 s at 120 BPM) }
  for i := 0 to 15 do
    tl.AddClip(tDrums.Id, sDrums.Id, Format('kick %d', [i + 1]), i * 0.5, 0, 0.45);
  { bass note per bar }
  for i := 0 to 3 do
    tl.AddClip(tBass.Id, sBass.Id, Format('bass %d', [i + 1]), i * 2.0, 0, 1.9);
  { a lead phrase over bars 2-4 with fades }
  with tl.AddClip(tLead.Id, sLead.Id, 'lead A', 2.0, 0, 4.0) do
  begin
    FadeInSeconds := 0.1;
    FadeOutSeconds := 0.5;
    GainDb := -2.0;
  end;

  tl.AddMarker('Intro', 0.0);
  tl.AddMarker('Verse', 4.0);
  tl.AddRegion('Lead phrase', 2.0, 4.0);
  tl.PlayheadSeconds := 0;

  FProject.Touch;
  FTlView.SetZoom(120);
  FTlView.ScrollToSeconds(0);
  Logger.Info('ui', 'timeline demo arrangement built');
end;

procedure TfrmMain.btnTlDemoClick(Sender: TObject);
begin
  try
    BuildDemoArrangement;
    RefreshTimelineTab;
  except
    on E: Exception do
      memTimeline.Lines.Insert(0, 'Demo build FAILED: ' + E.Message);
  end;
end;

procedure TfrmMain.pbTimelineMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  tl: TTimeline;
  c: TTimelineClip;
  trkForIdx: TTimelineTrack;
  sec: Double;
  ti, i: Integer;
  edge: TClipEdge;
  multi: Boolean;
  ids: TArray<Integer>;
begin
  { The timeline is a TPaintBox and can't take focus, so a text box clicked
    earlier (BPM, a rename, the log memo) kept it - and FormKeyDown ignores
    every hotkey while a text field is focused. That is why Delete/Insert/
    Home/End "randomly" stopped working. Clicking the timeline hands focus
    to the page control so the hotkeys are live again. }
  if (ActiveControl is TCustomEdit) or (ActiveControl is TCustomMemo) then
  begin
    if ActiveControl = edtTlTempo then
      edtTlTempoExit(edtTlTempo);   // commit a half-typed BPM like leaving the box would
    ActiveControl := pgc;
  end;
  if FProject = nil then Exit;
  tl := FProject.Timeline;
  FTlView.SetViewportWidth(pbTimeline.Width);

  { track under the cursor, header column included, so right-clicking a
    track's header (or an empty lane) can still target it for "Remove
    Timeline" - unlike clip selection, which needs the lane area. This is
    just bookkeeping for the context menu and never mutates the model, so
    it runs for every button, not only the left one. }
  if TlTrackAtY(Y, ti) then
  begin
    FTlCtxTrackId := tl.GetTrack(ti).Id;
    if Button = mbLeft then
    begin
      if (ssCtrl in Shift) or (ssShift in Shift) then
      begin
        { multi-select: keep the previous primary highlighted as an extra }
        if FTlSelectedTrackId <> FTlCtxTrackId then
        begin
          if TlExtraTrackIndex(FTlCtxTrackId) >= 0 then
            TlExtraTrackRemove(FTlCtxTrackId)
          else
          begin
            if (FTlSelectedTrackId >= 0) and
               (TlExtraTrackIndex(FTlSelectedTrackId) < 0) then
              FTlExtraTrackIds := FTlExtraTrackIds + [FTlSelectedTrackId];
            FTlSelectedTrackId := FTlCtxTrackId;
          end;
        end;
      end
      else
      begin
        FTlExtraTrackIds := nil;
        FTlSelectedTrackId := FTlCtxTrackId;
      end;
    end;
  end
  else
    FTlCtxTrackId := -1;

  if Button = mbMiddle then
  begin
    { middle-mouse-drag pans the timeline horizontally, FL-Studio-style;
      it never touches selection/track targeting or opens a popup. }
    FTlMiddlePanning := True;
    FTlMiddlePanLastX := X;
    pbTimeline.Cursor := crHSplit;
    Exit;
  end;

  { grab zone lies wholly on the header side of the boundary so the lane area
    (X >= HeaderWidth) never conflicts with range/clip selection }
  if (Button = mbLeft) and (X >= FTlView.HeaderWidth - 8) and (X < FTlView.HeaderWidth) then
  begin
    { left-drag on the header/lane boundary resizes the track-header column -
      see UDAW.Timeline.Model.TTimeline.HeaderWidth, persisted per-project. }
    FTlHeaderResizing := True;
    FTlHeaderResizeStartX := X;
    FTlHeaderResizeStartWidth := FTlView.HeaderWidth;
    pbTimeline.Cursor := crSizeWE;
    Exit;
  end;

  if Button <> mbLeft then
  begin
    { A right-click landing in the ruler (Y < RulerHeight) is a completely
      different context than one on a clip/lane - see pbTimelineMouseUp,
      which shows pmTimelineRuler instead of pmTimeline for it. Moving the
      playhead here first (snapped, same as a plain ruler left-click) means
      every ruler-menu command below - Add Marker/Set Loop Start/Set Loop
      End - can just act on tl.PlayheadSeconds like their existing toolbar
      counterparts (btnTlLoopStartClick etc.) instead of needing their own
      separate "clicked position" plumbing. }
    if (X >= FTlView.HeaderWidth) and (Y < FTlView.RulerHeight) then
    begin
      FTlRulerCtxActive := True;
      sec := FTlView.XToSeconds(X);
      if sec < 0 then sec := 0;
      tl.PlayheadSeconds := FTlView.Snap(sec);
    FRecInsertSeconds := tl.PlayheadSeconds;
      RefreshTimelineTab;
      Exit;
    end;
    FTlRulerCtxActive := False;

    { right-button down inside the lane with a range selected: dragging moves
      the selected range; a plain click (no movement) still opens the menu }
    if (Button = mbRight) and FTlRangeActive and (X >= FTlView.HeaderWidth) then
    begin
      FTlRangeMoving := True;
      FTlRangeMoveMoved := False;
      FTlRangeMoveDownX := X;
      FTlRangeMoveLastSec := FTlView.XToSeconds(X);
    end;

    { right/middle click must never start a drag/trim before the popup
      shows, but it should still re-target selection to whatever clip is
      under the cursor - like any DAW, right-clicking an unselected clip
      selects it so Cut/Copy/Split/Delete act on the thing you pointed at,
      not on a stale earlier left-click selection. A right-click on a clip
      that is already part of a multi-selection keeps the whole group
      selected, so context actions like Delete apply to all of them. }
    if X >= FTlView.HeaderWidth then
    begin
      c := TlClipAtPoint(X, Y);
      if (c <> nil) and not TlIsClipSelected(c.Id) then
      begin
        TlSetSingleSelection(c.Id);
        RefreshTimelineTab;
      end;
    end;
    Exit;
  end;

  if X < FTlView.HeaderWidth then
  begin
    { header mute button ("X"): live toggle, same monitoring-only semantics
      as pmTlMuteTrackClick - not run through the undo stack, and takes
      effect immediately mid-playback since TTimelinePlayer reads
      trk.Muted live per-sample. }
    if TlTrackAtY(Y, ti) and PtInRect(TlMuteButtonRect(TlTrackTop(ti)), Point(X, Y)) then
    begin
      trkForIdx := tl.GetTrack(ti);
      trkForIdx.Muted := not trkForIdx.Muted;
      FProject.Touch;
    end
    else if TlTrackAtY(Y, ti) and TlPrimaryTempoUnknown(tl.GetTrack(ti)) and
      PtInRect(TlTempoUnknownRect(TlTrackTop(ti), tl.GetTrack(ti).Height), Point(X, Y)) then
    begin
      FTlSelectedTrackId := tl.GetTrack(ti).Id;
      TlTempoUnknownClick;
      Exit;
    end;
    RefreshTimelineTab;  // show the Browser import destination immediately
    Exit;
  end;

  sec := FTlView.XToSeconds(X);
  if sec < 0 then sec := 0;

  if Y < FTlView.RulerHeight then
  begin
    { ruler click -> move the playhead (snapped); a left-drag from here
      instead defines a time-range "section" selection spanning every
      track, highlighted in pbTimelinePaint and consumed by the ruler
      context menu's range actions (Split at Range Edges / Delete Range /
      Set Loop to Selection). A drag that never actually moves collapses
      back to the plain click behaviour in pbTimelineMouseUp. }
    tl.PlayheadSeconds := FTlView.Snap(sec);
    FRecInsertSeconds := tl.PlayheadSeconds;
    FTlRangeDragging := True;
    FTlRangeAnchorSec := FTlView.Snap(sec);
    FTlRangeStartSec := FTlRangeAnchorSec;
    FTlRangeEndSec := FTlRangeAnchorSec;
    RefreshTimelineTab;
    Exit;
  end;

  FTlTrimming := False;
  FTlFadeDragging := False;
  FTlRubberSelecting := False;
  FTlRangeActive := False;   { any lane interaction below clears a pending range selection }
  { Ctrl+left-drag anywhere in the lanes (even over clips) highlights a time
    range, same as the ruler / empty-lane drag. Shift remains multi-select. }
  if ssCtrl in Shift then
  begin
    FTlRangeDragging := True;
    FTlRangeAnchorSec := FTlView.Snap(sec);
    FTlRangeStartSec := FTlRangeAnchorSec;
    FTlRangeEndSec := FTlRangeAnchorSec;
    RefreshTimelineTab;
    Exit;
  end;
  multi := ssShift in Shift;
  c := TlClipAtPoint(X, Y);
  if c <> nil then
  begin
    if multi then
      TlToggleSelection(c.Id)
    else if not TlIsClipSelected(c.Id) then
      TlSetSingleSelection(c.Id);
    { else: clicking an already-selected clip in a multi-selection keeps the
      whole group selected, so the drag below moves all of them together }

    if (not c.Locked) and TlHitTestFadeHandle(c, ti, X, Y, edge) then
    begin
      FTlFadeDragging := True;
      FTlFadeClipId := c.Id;
      FTlFadeEdge := edge;
    end
    else if (not c.Locked) and TlHitTestClipEdge(c, X, edge) then
    begin
      FTlTrimming := True;
      FTlTrimClipId := c.Id;
      FTlTrimEdge := edge;
    end
    else
    begin
      FTlDragging := True;
      FTlDragMouseStartSec := sec;
      FTlDragClipStartSec := c.StartSeconds;
      FTlDragStartTrackIdx := ti;   // track index under the cursor, i.e. c's own track (set by TlTrackAtY above)

      { Alt+drag duplicates the selection in place first (see
        TlDuplicateSelectedClips), then drags the copies - the originals
        stay put. Falls back to a normal move if duplication produced
        nothing (e.g. the clip vanished between hit-test and here). }
      ids := nil;
      if (ssAlt in Shift) and not c.Locked then
        ids := TlDuplicateSelectedClips;

      { snapshot every selected clip's start (and track index, so a vertical
        drag can carry the whole group to a different track together), for
        the move in pbTimelineMouseMove }
      if Length(ids) = 0 then
      begin
        SetLength(ids, 0);
        if FTlSelClipId >= 0 then
        begin
          SetLength(ids, Length(ids) + 1);
          ids[High(ids)] := FTlSelClipId;
        end;
        for i := 0 to High(FTlSelClipIds) do
        begin
          SetLength(ids, Length(ids) + 1);
          ids[High(ids)] := FTlSelClipIds[i];
        end;
      end;
      FTlDragIds := ids;
      SetLength(FTlMultiDragStartSecs, Length(ids));
      SetLength(FTlMultiDragStartTrackIdx, Length(ids));
      for i := 0 to High(ids) do
      begin
        FTlMultiDragStartSecs[i] := tl.ClipById(ids[i]).StartSeconds;
        tl.ClipById(ids[i], trkForIdx);
        FTlMultiDragStartTrackIdx[i] := TlTrackIndexById(trkForIdx.Id);
      end;
    end;
  end
  else if (FTlRubberBandMods <> []) and (FTlRubberBandMods <= Shift) then
  begin
    { rubber-band hook (FTlRubberBandMods, default Shift) on empty space: extend the current selection with a
      rubber band instead of clearing it }
    FTlRubberSelecting := True;
    FTlRubberStartX := X; FTlRubberStartY := Y;
    FTlRubberX := X; FTlRubberY := Y;
  end
  else
  begin
    { plain left-drag on empty lane space highlights a time range (worked on
      by the range menu actions); the playhead is only positioned from the
      ruler, never from the lane }
    TlSetSingleSelection(-1);
    FTlRangeDragging := True;
    FTlRangeAnchorSec := FTlView.Snap(sec);
    FTlRangeStartSec := FTlRangeAnchorSec;
    FTlRangeEndSec := FTlRangeAnchorSec;
  end;
  RefreshTimelineTab;
end;

procedure TfrmMain.pbTimelineMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  delta, newStart, sec, newFade, rawSec: Double;
  c: TTimelineClip;
  edge: TClipEdge;
  i, ti, curTrackIdx, deltaTrackIdx, newTrackIdx, newTrackId: Integer;
  origTrk, candTrk: TTimelineTrack;
begin
  if FProject = nil then Exit;

  if FTlMiddlePanning then
  begin
    FTlView.ScrollByPixels(FTlMiddlePanLastX - X);
    FTlMiddlePanLastX := X;
    RefreshTimelineTab;
    Exit;
  end;

  if FTlHeaderResizing then
  begin
    FProject.Timeline.HeaderWidth := FTlHeaderResizeStartWidth + (X - FTlHeaderResizeStartX);
    RefreshTimelineTab;
    Exit;
  end;

  if FTlRangeMoving then
  begin
    if Abs(X - FTlRangeMoveDownX) > 3 then FTlRangeMoveMoved := True;
    if FTlRangeMoveMoved then
    begin
      rawSec := FTlView.XToSeconds(X);
      delta := rawSec - FTlRangeMoveLastSec;
      if FTlRangeStartSec + delta < 0 then delta := -FTlRangeStartSec;
      FTlRangeStartSec := FTlRangeStartSec + delta;
      FTlRangeEndSec := FTlRangeEndSec + delta;
      FTlRangeMoveLastSec := FTlRangeMoveLastSec + delta;
      RefreshTimelineTab;
    end;
    Exit;
  end;

  if FTlRangeDragging then
  begin
    sec := FTlView.Snap(FTlView.XToSeconds(X));
    if sec < 0 then sec := 0;
    FTlRangeStartSec := Min(FTlRangeAnchorSec, sec);
    FTlRangeEndSec := Max(FTlRangeAnchorSec, sec);
    FTlRangeActive := (FTlRangeEndSec - FTlRangeStartSec) > 0.0005;
    RefreshTimelineTab;
    Exit;
  end;

  if FTlFadeDragging and (FTlFadeClipId >= 0) then
  begin
    c := FProject.Timeline.ClipById(FTlFadeClipId);
    if c = nil then
    begin
      FTlFadeDragging := False;
      Exit;
    end;
    rawSec := FTlView.XToSeconds(X);   { fades are fine-grained: never snapped to the grid }
    if FTlFadeEdge = ceStart then
      newFade := rawSec - c.StartSeconds
    else
      newFade := c.EndSeconds - rawSec;
    newFade := EnsureRange(newFade, 0, c.LengthSeconds);
    try
      FCmds.Perform(TSetTimelineClipFadeCommand.Create(FProject, FTlFadeClipId, FTlFadeEdge, newFade));
    except
      on E: Exception do
      begin
        FTlFadeDragging := False;
        memTimeline.Lines.Insert(0, 'Fade FAILED: ' + E.Message);
      end;
    end;
    RefreshTimelineTab;
    Exit;
  end;

  if FTlRubberSelecting then
  begin
    FTlRubberX := X; FTlRubberY := Y;
    TlSelectRubberBand;
    RefreshTimelineTab;
    Exit;
  end;

  if FTlTrimming and (FTlTrimClipId >= 0) then
  begin
    sec := FTlView.Snap(FTlView.XToSeconds(X));
    if sec < 0 then sec := 0;
    try
      FCmds.Perform(TTrimTimelineClipCommand.Create(FProject, FTlTrimClipId, FTlTrimEdge, sec));
    except
      on E: Exception do
      begin
        FTlTrimming := False;
        memTimeline.Lines.Insert(0, 'Trim FAILED: ' + E.Message);
      end;
    end;
    RefreshTimelineTab;
    Exit;
  end;

  if not FTlDragging or (FTlSelClipId < 0) then
  begin
    { hover feedback: a resize cursor over a draggable clip edge, or a
      diagonal-resize cursor over a fade handle corner }
    c := TlClipAtPoint(X, Y);
    if (X >= FTlView.HeaderWidth - 8) and (X < FTlView.HeaderWidth) then
      pbTimeline.Cursor := crSizeWE
    else if (c <> nil) and not c.Locked and TlTrackAtY(Y, ti) and
       TlHitTestFadeHandle(c, ti, X, Y, edge) then
      pbTimeline.Cursor := crSizeAll
    else if (c <> nil) and not c.Locked and TlHitTestClipEdge(c, X, edge) then
      pbTimeline.Cursor := crSizeWE
    else
      pbTimeline.Cursor := crDefault;
    Exit;
  end;

  { group move: every clip captured in FTlDragIds/FTlMultiDragStartSecs at
    mouse-down rides the same delta, so a multi-selected drag keeps the
    clips' relative offsets exactly as they were - like every other DAW's
    playlist/arrangement view. A vertical drag carries the same track-index
    delta onto each clip's own start track, so dragging a clip (or a whole
    selection) onto a different lane re-parents it there - but only when the
    destination track is the same kind as the clip's own track (an audio
    clip dragged onto e.g. a Tracker/MIDI lane just keeps its original track,
    so a diagonal drag can't silently misfile it into an incompatible lane). }
  delta := FTlView.XToSeconds(X) - FTlDragMouseStartSec;
  if TlTrackAtY(Y, curTrackIdx) then
    deltaTrackIdx := curTrackIdx - FTlDragStartTrackIdx
  else
    deltaTrackIdx := 0;
  try
    for i := 0 to High(FTlDragIds) do
    begin
      newStart := FTlView.Snap(FTlMultiDragStartSecs[i] + delta);
      if newStart < 0 then newStart := 0;
      newTrackId := 0;   // 0 = TMoveTimelineClipCommand keeps the clip's current track
      if (deltaTrackIdx <> 0) and (i <= High(FTlMultiDragStartTrackIdx)) and
         (FTlMultiDragStartTrackIdx[i] >= 0) then
      begin
        newTrackIdx := EnsureRange(FTlMultiDragStartTrackIdx[i] + deltaTrackIdx,
          0, FProject.Timeline.TrackCount - 1);
        if newTrackIdx <> FTlMultiDragStartTrackIdx[i] then
        begin
          origTrk := FProject.Timeline.GetTrack(FTlMultiDragStartTrackIdx[i]);
          candTrk := FProject.Timeline.GetTrack(newTrackIdx);
          if candTrk.Kind = origTrk.Kind then
            newTrackId := candTrk.Id;
        end;
      end;
      FCmds.Perform(TMoveTimelineClipCommand.Create(FProject, FTlDragIds[i], newStart, newTrackId));
    end;
  except
    on E: Exception do
    begin
      FTlDragging := False;
      memTimeline.Lines.Insert(0, 'Move FAILED: ' + E.Message);
    end;
  end;
  RefreshTimelineTab;
end;

procedure TfrmMain.pbTimelineMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  pt: TPoint;
begin
  FTlDragging := False;
  FTlTrimming := False;
  FTlFadeDragging := False;
  FTlRangeDragging := False;
  if FTlRangeMoving then
  begin
    FTlRangeMoving := False;
    if (Button = mbRight) and FTlRangeMoveMoved then
    begin
      FTlRangeMoveMoved := False;
      RefreshTimelineTab;
      Exit;   // it was a drag, not a click - no context menu
    end;
  end;
  if FTlMiddlePanning then
  begin
    FTlMiddlePanning := False;
    pbTimeline.Cursor := crDefault;
  end;
  if FTlHeaderResizing then
  begin
    FTlHeaderResizing := False;
    pbTimeline.Cursor := crDefault;
    if FProject <> nil then FProject.Touch;   // commits the resized width to the project's dirty/undo-save state
  end;
  if FTlRubberSelecting then
  begin
    FTlRubberSelecting := False;
    RefreshTimelineTab;
  end;
  if Button = mbRight then
  begin
    { pmTimeline is shown manually here, on purpose, instead of via the
      pbTimeline.PopupMenu property VCL would otherwise auto-invoke: a
      popup shown that way is tracked through Vcl.Menus' own hidden helper
      window, not this form, so WM_ENTERMENULOOP/WM_EXITMENULOOP never
      reached TfrmMain for it - FMenuLoopActive stayed False the entire
      time the menu was open, so nothing was ever actually stopping
      tmrUITimer's per-tick pbTimeline.Invalidate from repainting
      underneath the live popup (the fix that was supposed to prevent the
      blank/flickering menu never engaged for THIS menu, only for the main
      menu bar's Timeline dropdown, which genuinely is owned by the form).
      Popup(...) blocks until the menu closes, so wrapping the one call
      that actually matters here sidesteps the whole hidden-window problem
      instead of depending on which window Windows happens to route those
      messages to. }
    pt := pbTimeline.ClientToScreen(Point(X, Y));
    FMenuLoopActive := True;
    try
      if FTlRulerCtxActive then
        pmTimelineRuler.Popup(pt.X, pt.Y)
      else
        pmTimeline.Popup(pt.X, pt.Y);
    finally
      FMenuLoopActive := False;
    end;
  end;
end;

procedure TfrmMain.pbTimelinePaint(Sender: TObject);
const
  CLIP_HEADER_H = 15;
  EDGE_R = 5;
var
  cv: TCanvas;
  w, h, ti, j, top, laneH, x, x2, cw: Integer;
  tl: TTimeline;
  grid: TGridContext;
  trk: TTimelineTrack;
  clip: TTimelineClip;
  src: TMediaSource;
  barSec, tSec, sx: Double;
  barIdx: Integer;
  cols: TWavePeakArray;
  midY, halfH, px, colFirstSec, spc, srcScale: Double;
  ch, colX: Integer;
  pk: TWavePeak;
  isSel: Boolean;
  trackHasEffects: Boolean;
  clipBackground: TColor;
  fadeX: Integer;
  playX, loopX1, loopX2, rngX1, rngX2: Double;
  theme: TUDAWTheme;
  bodyTop: Integer;
  badgeX: Integer;
  muteRect, titleRect: TRect;
  smallFontH: Integer;
  clipSave: Integer;
  clipLabel: string;

  procedure DrawFittedLabel(const AText: string; AX, AY, ARight, ABottom: Integer);
  var
    labelText: string;
    lo, hi, mid, available: Integer;
    bounds: TRect;
  begin
    available := ARight - AX;
    if (available <= 0) or (ABottom <= AY) then Exit;
    labelText := AText;
    if cv.TextWidth(labelText) > available then
    begin
      if cv.TextWidth('...') > available then Exit;
      lo := 0;
      hi := Length(AText);
      while lo < hi do
      begin
        mid := (lo + hi + 1) div 2;
        if cv.TextWidth(Copy(AText, 1, mid) + '...') <= available then lo := mid
        else hi := mid - 1;
      end;
      if (lo > 0) and (Ord(AText[lo]) >= $D800) and (Ord(AText[lo]) <= $DBFF) then Dec(lo);
      labelText := Copy(AText, 1, lo) + '...';
    end;
    bounds := Rect(AX, AY, ARight, ABottom);
    cv.TextRect(bounds, AX, AY, labelText);
  end;

  procedure VLine(AX, AY1, AY2: Integer; AColor: TColor);
  begin
    cv.Pen.Color := AColor;
    cv.MoveTo(AX, AY1);
    cv.LineTo(AX, AY2);
  end;

  { blend two TColor values by T in [0,1]; goes through ColorToRGB (not
    GetRValue/RGB, which live in Winapi.Windows and aren't available under
    FPC/LCL) so this works unchanged on both build targets. }
  function Mix(A, B: TColor; T: Double): TColor;
  var
    ca, cb: LongInt;
    ar, ag, ab, br, bg, bb: Byte;
  begin
    ca := ColorToRGB(A);
    cb := ColorToRGB(B);
    ar := ca and $FF; ag := (ca shr 8) and $FF; ab := (ca shr 16) and $FF;
    br := cb and $FF; bg := (cb shr 8) and $FF; bb := (cb shr 16) and $FF;
    Result := TColor(Byte(Round(ar + (br - ar) * T)) or
      (Byte(Round(ag + (bg - ag) * T)) shl 8) or
      (Byte(Round(ab + (bb - ab) * T)) shl 16));
  end;

  { small filled badge with a 1-char label, for M/S/L track/clip indicators }
  procedure Badge(var AX: Integer; AY: Integer; AColor: TColor; const ALabel: string);
  const
    BW = 15; BH = 13;
  begin
    cv.Brush.Style := bsSolid;
    cv.Brush.Color := AColor;
    cv.Pen.Color := Mix(AColor, clBlack, 0.35);
    cv.RoundRect(AX, AY, AX + BW, AY + BH, 4, 4);
    cv.Brush.Style := bsClear;
    cv.Font.Color := clBlack;
    cv.TextOut(AX + 4, AY - 1, ALabel);
    cv.Brush.Style := bsSolid;
    Inc(AX, BW + 3);
  end;

begin
  w := pbTimeline.Width;
  h := pbTimeline.Height;
  if (w <= 0) or (h <= 0) then Exit;
  { paint into an off-screen bitmap and blit it in one shot - pbTimeline is
    invalidated at near-frame rate during playback, and drawing this many
    lines/rects/waveform columns straight to the on-screen DC flickered
    badly; this is what "double buffer the timeline" fixes. }
  FTlBuffer.SetSize(w, h);
  cv := FTlBuffer.Canvas;
  theme := CurrentTheme;
  cv.Brush.Color := theme.Background;
  cv.Brush.Style := bsSolid;
  cv.FillRect(Rect(0, 0, w, h));

  if FProject <> nil then
  begin
  tl := FProject.Timeline;
  grid := TimelineGrid;
  FTlView.SetGrid(grid);
  FTlView.SetViewportWidth(w);

  { ---- loop region shading on the ruler ---- }
  if tl.LoopLengthSeconds > 0 then
  begin
    loopX1 := FTlView.SecondsToX(tl.LoopStartSeconds);
    loopX2 := FTlView.SecondsToX(tl.LoopStartSeconds + tl.LoopLengthSeconds);
    if (loopX2 >= FTlView.HeaderWidth) and (loopX1 <= w) then
    begin
      if loopX1 < FTlView.HeaderWidth then loopX1 := FTlView.HeaderWidth;
      if loopX2 > w then loopX2 := w;
      cv.Brush.Style := bsSolid;
      if tl.LoopEnabled then
        cv.Brush.Color := theme.Accent
      else
        cv.Brush.Color := theme.SecondaryText;
      cv.Pen.Style := psClear;
      cv.Rectangle(Round(loopX1), 0, Round(loopX2), FTlView.RulerHeight);
      cv.Pen.Style := psSolid;
    end;
  end;

  { ---- range/section selection: a tinted ruler-strip fill so a drag-
    selected time range reads at a glance, distinct from the loop-region
    fill above (Selection is a different theme colour from Accent). The
    full-height dashed boundary lines are drawn later, after the clips, so
    they stay visible over waveforms/clip bodies instead of being painted
    under them. ---- }
  if FTlRangeActive then
  begin
    rngX1 := FTlView.SecondsToX(FTlRangeStartSec);
    rngX2 := FTlView.SecondsToX(FTlRangeEndSec);
    if (rngX2 >= FTlView.HeaderWidth) and (rngX1 <= w) then
    begin
      if rngX1 < FTlView.HeaderWidth then rngX1 := FTlView.HeaderWidth;
      if rngX2 > w then rngX2 := w;
      cv.Brush.Style := bsSolid;
      cv.Brush.Color := Mix(theme.Selection, theme.Background, 0.25);
      cv.Pen.Style := psClear;
      cv.Rectangle(Round(rngX1), 0, Round(rngX2), FTlView.RulerHeight);
      cv.Pen.Style := psSolid;
    end;
  end;

  { ---- bar/beat grid over the lane area ---- }
  if grid.IsValid then
  begin
    barSec := grid.SecondsPerBar;
    barIdx := Trunc(FTlView.VisibleStartSeconds / barSec) - 1;
    if barIdx < 0 then barIdx := 0;
    repeat
      tSec := barIdx * barSec;
      sx := FTlView.SecondsToX(tSec);
      if sx > w then Break;
      if sx >= FTlView.HeaderWidth then
      begin
        VLine(Round(sx), 0, h, theme.Grid);
        cv.Brush.Style := bsClear;
        cv.Font.Color := theme.SecondaryText;
        cv.TextOut(Round(sx) + 2, 2, IntToStr(barIdx + 1));
        cv.Brush.Style := bsSolid;
      end;
      Inc(barIdx);
    until sx > w;
  end;

  { ---- ruler baseline ---- }
  cv.Pen.Color := theme.Border;
  cv.MoveTo(0, FTlView.RulerHeight);
  cv.LineTo(w, FTlView.RulerHeight);

  { ---- master spectrum in the top-left corner (resizes with HeaderWidth) ---- }
  DrawTimelineSpectrum(cv, Rect(0, 0, FTlView.HeaderWidth - 1, FTlView.RulerHeight - 1));

  { ---- markers ---- }
  for j := 0 to tl.MarkerCount - 1 do
  begin
    sx := FTlView.SecondsToX(tl.GetMarker(j).Seconds);
    if (sx >= FTlView.HeaderWidth) and (sx <= w) then
    begin
      cv.Brush.Color := theme.Automation;
      cv.Pen.Color := theme.Automation;
      cv.Polygon([Point(Round(sx), 4), Point(Round(sx) - 5, 14), Point(Round(sx) + 5, 14)]);
      cv.Brush.Color := theme.Background;
      cv.Brush.Style := bsClear;
      cv.Font.Color := theme.Text;
      cv.TextOut(Round(sx) + 6, 3, tl.GetMarker(j).Name);
      cv.Brush.Style := bsSolid;
    end;
  end;

  { ---- tracks ----
    Clipped to [RulerHeight, h] for the whole loop: with the vertical
    scrollbar (sbTlVert/FTlVScrollY), a track's title band/content can land
    above the ruler while scrolling, and without this it would paint straight
    over the ruler - which must stay a fixed, un-scrolled "sticky header" at
    all times. }
  clipSave := SaveDC(cv.Handle);
  IntersectClipRect(cv.Handle, 0, FTlView.RulerHeight, w, h);
  try
    for ti := 0 to tl.TrackCount - 1 do
    begin
      trk := tl.GetTrack(ti);
      top := TlTrackTop(ti);
      trackHasEffects := FProject.Mixer.SourceHasEffects(trk.Id);
      laneH := trk.Height;
      if top > h then Break;
      if top + laneH < FTlView.RulerHeight then Continue;

    { per-channel title band: sits directly over this track, above its own
      header/name and above the clip filename in its lane - not the global
      ruler at the very top of the timeline - so section titles and "effect
      added" names for THIS channel are never confused with another track's,
      and never collide with the ruler's numerical bar labels. Small font,
      one line, saved with the project on TTimelineTrack.Title. }
    titleRect := TlTrackTitleRect(top, w);
    if titleRect.Bottom > titleRect.Top then
    begin
      cv.Brush.Style := bsSolid;
      cv.Brush.Color := Mix(theme.PanelBackground, theme.Background, 0.45);
      cv.FillRect(titleRect);
      cv.Pen.Color := theme.Border;
      cv.MoveTo(titleRect.Left, titleRect.Bottom); cv.LineTo(titleRect.Right, titleRect.Bottom);
      { The track-wide trk.Title is deliberately NOT drawn: it held a stale
        comma-joined list of every effect ever added (saved in older projects),
        piled at the channel start. Only the per-region names below are shown,
        each where that effect is actually present. }
      { each rendered-effect region is named here, at the region's own start,
        in that effect's colour }
      smallFontH := cv.Font.Height;
      cv.Font.Height := Round(smallFontH * 0.8);
      cv.Brush.Style := bsClear;
      for j := 0 to trk.ClipCount - 1 do
      begin
        clip := trk.GetClip(j);
        if (clip.EndSeconds < FTlView.XToSeconds(FTlView.HeaderWidth)) or
           (clip.StartSeconds > FTlView.XToSeconds(w)) then Continue;
        for var reg in TlClipRegions(clip) do
        begin
          var regEnd := clip.EndSeconds;
          if reg.LengthSeconds > 0 then
            regEnd := Min(clip.EndSeconds, clip.StartSeconds + reg.OffsetSeconds + reg.LengthSeconds);
          x := Round(FTlView.SecondsToX(
            Max(clip.StartSeconds + Min(reg.OffsetSeconds, clip.LengthSeconds),
              FTlView.XToSeconds(FTlView.HeaderWidth))));
          x2 := Round(FTlView.SecondsToX(Min(regEnd, FTlView.XToSeconds(w))));
          cv.Font.Color := reg.Color;
          DrawFittedLabel(reg.Name, x + 3, titleRect.Top + 1,
            Min(x2, titleRect.Right) - 2, titleRect.Bottom - 1);
        end;
      end;
      cv.Font.Height := smallFontH;
    end;

    { header, with a subtle divider below and a slightly lighter fill so it
      reads as a distinct control column rather than more lane background }
    if (trk.Id = FTlSelectedTrackId) or TlTrackHasSelectedClip(trk) then
      cv.Brush.Color := Mix(theme.Selection, theme.PanelBackground, 0.6)
    else
      cv.Brush.Color := Mix(theme.PanelBackground, theme.Background, 0.15);
    cv.Brush.Style := bsSolid;
    cv.FillRect(Rect(0, top, FTlView.HeaderWidth, top + laneH));
    cv.Pen.Color := theme.Border;
    cv.MoveTo(0, top + laneH); cv.LineTo(w, top + laneH);
    cv.MoveTo(FTlView.HeaderWidth, top); cv.LineTo(FTlView.HeaderWidth, top + laneH);
    { horizontal splitter: a 5px grab strip at the header/lane boundary,
      inside the header column so it clears both the header content and the
      channel data. }
    cv.Brush.Color := Mix(theme.Border, theme.PanelBackground, 0.5);
    cv.FillRect(Rect(FTlView.HeaderWidth - 5, top, FTlView.HeaderWidth, top + laneH));
    { mute button - a real toggle button, not just a status badge: pressed-in
      and highlighted while the track is muted, flat/normal otherwise. Fixed
      top-left corner of the header so it stays in the same spot across every
      track regardless of name length; pbTimelineMouseDown hit-tests this
      exact rect (see TlMuteButtonRect). }
    cv.Brush.Style := bsSolid;
    if trk.Muted then
    begin
      cv.Brush.Color := theme.MeterClip;
      cv.Pen.Color := Mix(theme.MeterClip, clBlack, 0.4);
    end
    else
    begin
      cv.Brush.Color := Mix(theme.PanelBackground, theme.Background, 0.3);
      cv.Pen.Color := theme.Border;
    end;
    muteRect := TlMuteButtonRect(top);
    cv.RoundRect(muteRect.Left, muteRect.Top, muteRect.Right, muteRect.Bottom, 3, 3);
    cv.Brush.Style := bsClear;
    cv.Font.Color := IfThen(trk.Muted, clWhite, theme.SecondaryText);
    cv.TextOut(muteRect.Left + 5, muteRect.Top + 1, 'X');
    cv.Font.Color := theme.Text;
    DrawFittedLabel(trk.Name, 26, top + 5, FTlView.HeaderWidth - 34, top + 20);
    if trk.Id = FTlSelectedTrackId then
    begin
      cv.Font.Color := theme.Accent;
      cv.TextOut(FTlView.HeaderWidth - 28, top + 5, 'IN');
    end;
    cv.Font.Color := theme.SecondaryText;
    cv.TextOut(26, top + 20, Format('%s  %.1f dB', [TrackKindDisplay(trk.Kind), trk.GainDb]));
    cv.Brush.Style := bsSolid;
    { Video channels get a prominent filled tag in the header so users can
      tell video from audio/music channels at a glance. }
    if trk.Kind = tkVideo then
    begin
      cv.Brush.Color := $00C06020;
      cv.Pen.Color := Mix($00C06020, clBlack, 0.4);
      cv.RoundRect(FTlView.HeaderWidth - 58, top + laneH - 20, FTlView.HeaderWidth - 10, top + laneH - 4, 4, 4);
      cv.Brush.Style := bsClear;
      cv.Font.Color := clWhite;
      cv.TextOut(FTlView.HeaderWidth - 52, top + laneH - 20, 'VIDEO');
      cv.Font.Color := theme.SecondaryText;
      cv.Brush.Style := bsSolid;
    end;

    { "?" - tempo unknown on the primary channel (baseline BPM could not be
      established); click to enter it. Gone once the tempo is known. }
    if TlPrimaryTempoUnknown(trk) then
    begin
      muteRect := TlTempoUnknownRect(top, laneH);
      cv.Brush.Color := $0030C0F0;
      cv.Pen.Color := Mix($0030C0F0, clBlack, 0.4);
      cv.RoundRect(muteRect.Left, muteRect.Top, muteRect.Right, muteRect.Bottom, 3, 3);
      cv.Brush.Style := bsClear;
      cv.Font.Color := clBlack;
      cv.TextOut(muteRect.Left + 5, muteRect.Top + 1, '?');
      cv.Font.Color := theme.SecondaryText;
      cv.Brush.Style := bsSolid;
    end;

    { solo/arm badges - filled and colour-coded, not just letters in text;
      mute now has its own dedicated button above, so it is not repeated here }
    badgeX := 6;
    if trk.Soloed then Badge(badgeX, top + laneH - 17, $0030C0F0, 'S');
    if trk.Armed then Badge(badgeX, top + laneH - 17, $004040F0, 'R');

    { lane background }
    cv.Brush.Color := theme.Background;
    cv.FillRect(Rect(FTlView.HeaderWidth, top, w, top + laneH));

    { clips }
    for j := 0 to trk.ClipCount - 1 do
    begin
      clip := trk.GetClip(j);
      { Clamp both edges to the viewport BEFORE any further math: a clip far
        outside the visible window (long clip during fast playback
        auto-scroll, or a very high zoom level) can make SecondsToX return a
        pixel offset well beyond Integer's range, and Round() truncating an
        out-of-range value wraps to an arbitrary small number instead of
        raising - which could then slip past the old bounds check and get
        drawn (fade lines/handles included) at a bogus on-screen position
        that has nothing to do with the clip's real, off-screen location.
        Clamping the SECONDS-domain value first keeps every pixel coordinate
        computed below inside [HeaderWidth, w], so nothing can wrap. }
      x := Round(FTlView.SecondsToX(
        Max(clip.StartSeconds, FTlView.XToSeconds(FTlView.HeaderWidth) - 1)));
      x2 := Round(FTlView.SecondsToX(
        Min(clip.EndSeconds, FTlView.XToSeconds(w) + 1)));
      if (clip.EndSeconds < FTlView.XToSeconds(FTlView.HeaderWidth)) or
         (clip.StartSeconds > FTlView.XToSeconds(w)) then Continue;
      if x < FTlView.HeaderWidth then x := FTlView.HeaderWidth;
      if x2 > w then x2 := w;
      cw := x2 - x;
      if cw < 1 then cw := 1;

      { rounded body, a thin header strip carrying the name, subtle border,
        brighter+accent-bordered when selected (single or multi), dimmed when muted }
      isSel := TlIsClipSelected(clip.Id);
      if clip.HasEffects or trackHasEffects then clipBackground := theme.ClipEffectsBackground
      else clipBackground := theme.PanelBackground;
      if isSel then clipBackground := Mix(clipBackground, theme.Selection, 0.35);
      if clip.Muted then clipBackground := Mix(clipBackground, theme.Background, 0.5);
      cv.Brush.Color := clipBackground;
      if isSel then cv.Pen.Color := theme.Selection
      else cv.Pen.Color := theme.Border;
      cv.Pen.Width := IfThen(isSel, 2, 1);
      cv.RoundRect(x, top + 2, x2, top + laneH - 2, EDGE_R, EDGE_R);
      cv.Pen.Width := 1;

      bodyTop := top + 2 + CLIP_HEADER_H;
      if bodyTop < top + laneH - 2 then
      begin
        { header strip stays neutral; an applied effect's colour is confined to
          its own region (below), not the whole clip }
        cv.Brush.Color := Mix(theme.PanelBackground, clBlack, 0.2);
        if (clip.EffectName = '') and (clip.Color <> 0) then
          cv.Brush.Color := clip.Color;
        cv.Pen.Color := cv.Brush.Color;
        cv.RoundRect(x, top + 2, x2, bodyTop, EDGE_R, EDGE_R);
        { every applied effect keeps its own coloured span, in application order }
        for var reg in TlClipRegions(clip) do
          if reg.Color <> 0 then
          begin
            var fxX1 := EnsureRange(Round(FTlView.SecondsToX(clip.StartSeconds + reg.OffsetSeconds)), x, x2);
            var fxX2 := x2;
            if reg.LengthSeconds > 0 then
              fxX2 := EnsureRange(Round(FTlView.SecondsToX(
                clip.StartSeconds + reg.OffsetSeconds + reg.LengthSeconds)), x, x2);
            if fxX2 > fxX1 then
            begin
              cv.Brush.Color := reg.Color;
              cv.FillRect(Rect(fxX1, top + 3, fxX2, bodyTop));
            end;
          end;
        cv.Pen.Color := theme.Border;
        cv.MoveTo(x + 1, bodyTop); cv.LineTo(x2 - 1, bodyTop);
      end;

      cv.Brush.Style := bsClear;
      cv.Font.Color := theme.Text;
      { the effect's name, right at the clip's own start (region start point)
        rather than a fixed screen position - x is recomputed every paint
        from FTlView's current scroll/zoom, so this moves with the clip and
        tracks live playback scroll exactly like the clip body itself; the
        header strip behind it is already painted in that effect's assigned
        colour (clip.Color, set by TlApplyEffectToRange/TlApplySilenceToRange
        via TlEffectColor) }
      clipLabel := clip.Name;
      if clip.Locked then
        DrawFittedLabel(clipLabel, x + 4, top + 3, x2 - 18, bodyTop)
      else
        DrawFittedLabel(clipLabel, x + 4, top + 3, x2 - 4, bodyTop);
      if clip.Locked and (cw >= 18) then
      begin
        cv.Font.Color := theme.MeterClip;
        DrawFittedLabel('L', x2 - 14, top + 3, x2 - 2, bodyTop);
      end;
      cv.Brush.Style := bsSolid;

      { ---- real waveform from the peak cache ---- }
      if (CurrentFadeDisplay <> fdmCurves) and (bodyTop < top + laneH - 3) and (cw > 4) then
      begin
        if clip.FadeInSeconds > 0 then
        begin
          fadeX := EnsureRange(Round(FTlView.SecondsToX(
            Min(clip.StartSeconds + clip.FadeInSeconds, FTlView.XToSeconds(w) + 1))), x, x2);
          cv.Brush.Color := theme.FadeInBackground;
          if isSel then cv.Brush.Color := Mix(cv.Brush.Color, theme.Selection, 0.25);
          if clip.Muted then cv.Brush.Color := Mix(cv.Brush.Color, theme.Background, 0.5);
          cv.FillRect(Rect(x + 2, bodyTop + 1, Min(x2 - 2, Max(x + 2, fadeX)), top + laneH - 3));
        end;
        if clip.FadeOutSeconds > 0 then
        begin
          fadeX := EnsureRange(Round(FTlView.SecondsToX(
            Max(clip.EndSeconds - clip.FadeOutSeconds, FTlView.XToSeconds(FTlView.HeaderWidth) - 1))), x, x2);
          cv.Brush.Color := theme.FadeOutBackground;
          if isSel then cv.Brush.Color := Mix(cv.Brush.Color, theme.Selection, 0.25);
          if clip.Muted then cv.Brush.Color := Mix(cv.Brush.Color, theme.Background, 0.5);
          cv.FillRect(Rect(Max(x + 2, Min(x2 - 2, fadeX)), bodyTop + 1, x2 - 2, top + laneH - 3));
        end;
      end;
      src := nil;
      if clip.SourceId >= 0 then src := tl.SourceById(clip.SourceId);
      { Usually a no-op: WarmClipWaveform already built this at import time.
        Still needed for a clip whose source was reloaded from an older
        project file, where nothing has called it yet - but this runs inside
        OnPaint, which WarmClipWaveform is NOT safe to call from: it shows a
        status-bar progress bracket and its per-chunk callback both pump
        Application.ProcessMessages, and ProcessMessages inside a paint
        handler can dispatch another paint (or the playback timer's own
        Invalidate) before this one returns - re-entering this same loop for
        the same still-nil Waveform and recursing again, each level pumping
        messages that spawn a deeper level. That reentrant loop is what made
        adding/playing a real clip look permanently frozen with the progress
        bar flickering at 0%, never advancing. Building the cache directly
        with no progress callback avoids ProcessMessages entirely - a bare,
        synchronous, one-time-per-source decode, exactly like any other paint
        work that happens to be slow the first time. }
      { Video clips have no waveform: draw a film-strip body (dark band with
        sprocket holes) and a VIDEO tag instead, so they read as video at a
        glance next to audio clips. }
      if (src <> nil) and (src.Kind = mkVideoFile) and (bodyTop < top + laneH - 3) and (cw > 4) then
      begin
        cv.Brush.Color := Mix($00401818, clBlack, 0.3);
        cv.FillRect(Rect(x + 2, bodyTop + 1, x2 - 2, top + laneH - 3));
        cv.Brush.Color := $00A0A0A0;
        var holeX := x + 6;
        while holeX < x2 - 8 do
        begin
          cv.FillRect(Rect(holeX, bodyTop + 3, holeX + 5, bodyTop + 8));
          cv.FillRect(Rect(holeX, top + laneH - 11, holeX + 5, top + laneH - 6));
          Inc(holeX, 14);
        end;
        cv.Brush.Style := bsClear;
        cv.Font.Color := $00E0C080;
        if cw > 60 then cv.TextOut(x + 8, bodyTop + (top + laneH - bodyTop) div 2 - 7, 'VIDEO');
        cv.Brush.Style := bsSolid;
      end;
      if (src <> nil) and (src.Waveform = nil) and (src.Kind <> mkVideoFile) then
        try
          src.EnsureWaveform;
        except
          on E: Exception do
            Logger.Warn('ui', 'waveform build failed: ' + E.Message);
        end;

      midY := bodyTop + (top + laneH - 2 - bodyTop) / 2;
      halfH := (top + laneH - 2 - bodyTop - 4) / 2;
      if (src <> nil) and (src.Waveform <> nil) and (src.SampleRate > 0) and (halfH > 2) then
      begin
        { A tempo-conformed clip plays the stretched copy, so one timeline
          second covers 1/factor seconds of the original file (factor = source
          BPM / project BPM, the same rule as the player's ClipStretchFactor).
          Without this the waveform showed the un-stretched file and ran past
          where the stretched audio actually ends. }
        srcScale := 1.0;
        if (clip.SourceBPM > 0) and (FProject.TempoBPM > 0) and not clip.IsMidiClip then
        begin
          spc := clip.SourceBPM / FProject.TempoBPM;
          if (Abs(spc - 1.0) >= 0.001) and (spc >= 0.25) and (spc <= 4.0) then
            srcScale := 1.0 / spc;
        end;
        spc := srcScale * src.SampleRate / FTlView.PixelsPerSecond;
        if spc < 1 then spc := 1;
        colFirstSec := clip.SourceOffsetSeconds +
          ((x - FTlView.SecondsToX(clip.StartSeconds)) / FTlView.PixelsPerSecond) * srcScale;
        ch := 0;
        { waveform: the effect's colour only inside the effect region }
        var regs := TlClipRegions(clip);
        var baseCol := theme.Waveform;
        if isSel then baseCol := Mix(baseCol, clWhite, 0.3);
        for colX := 0 to cw - 1 do
        begin
          cv.Pen.Color := baseCol;
          { the most recently applied region covering this column wins }
          var colSec := FTlView.XToSeconds(x + colX);
          for var ri := High(regs) downto 0 do
            if (regs[ri].Color <> 0) and (colSec >= clip.StartSeconds + regs[ri].OffsetSeconds) and
               ((regs[ri].LengthSeconds <= 0) or
                (colSec <= clip.StartSeconds + regs[ri].OffsetSeconds + regs[ri].LengthSeconds)) then
            begin
              cv.Pen.Color := regs[ri].Color;
              if isSel then cv.Pen.Color := Mix(cv.Pen.Color, clWhite, 0.3);
              Break;
            end;
          px := colFirstSec + colX / FTlView.PixelsPerSecond * srcScale;
          if clip.Reversed then
            src.Waveform.GetColumns(ch,
              Round((clip.SourceOffsetSeconds + clip.LengthSeconds * srcScale -
                     (px - clip.SourceOffsetSeconds)) * src.SampleRate),
              Round(spc), 1, cols)
          else
            src.Waveform.GetColumns(ch, Round(px * src.SampleRate), Round(spc), 1, cols);
          if Length(cols) = 0 then Continue;
          pk := cols[0];
          { A source can genuinely exceed +-1.0 (e.g. an unnormalized tracker
            bounce) - clamp the drawn line to the clip's own body rect rather
            than letting it paint into the lane above/below. }
          cv.MoveTo(x + colX, EnsureRange(Round(midY - pk.MaxV * halfH), bodyTop, top + laneH - 2));
          cv.LineTo(x + colX, EnsureRange(Round(midY - pk.MinV * halfH), bodyTop, top + laneH - 2));
        end;
      end
      else
      begin
        { no cache (missing file / generated) - a flat centre line, never a fake wave }
        cv.Pen.Color := theme.SecondaryText;
        cv.MoveTo(x + 1, Round(midY));
        cv.LineTo(x2 - 1, Round(midY));
      end;

      { Optional curve display uses the same ramp function as audio playback. }
      if CurrentFadeDisplay <> fdmColours then
      begin
        cv.Pen.Color := theme.Automation;
        for colX := x to x2 do
        begin
          px := FTlView.XToSeconds(colX);
          if (clip.FadeInSeconds > 0) and (px >= clip.StartSeconds) and
            (px <= clip.StartSeconds + clip.FadeInSeconds) then
          begin
            halfH := ShapeRamp(clip.FadeInShape, (px - clip.StartSeconds) / clip.FadeInSeconds);
            fadeX := Round(top + laneH - 3 - halfH * (top + laneH - 3 - bodyTop));
            if (colX = x) or (FTlView.XToSeconds(colX - 1) < clip.StartSeconds) then
              cv.MoveTo(colX, fadeX)
            else cv.LineTo(colX, fadeX);
          end;
          if (clip.FadeOutSeconds > 0) and (px >= clip.EndSeconds - clip.FadeOutSeconds) and
            (px <= clip.EndSeconds) then
          begin
            halfH := ShapeRamp(clip.FadeOutShape, (clip.EndSeconds - px) / clip.FadeOutSeconds);
            fadeX := Round(top + laneH - 3 - halfH * (top + laneH - 3 - bodyTop));
            if (colX = x) or (FTlView.XToSeconds(colX - 1) < clip.EndSeconds - clip.FadeOutSeconds) then
              cv.MoveTo(colX, fadeX)
            else cv.LineTo(colX, fadeX);
          end;
        end;
        if (bodyTop < top + laneH - 2) and (cw >= 12) then
        begin
          cv.Brush.Color := theme.Automation;
          cv.Pen.Color := Mix(theme.Automation, clBlack, 0.3);
          cv.Rectangle(x, bodyTop, x + 6, bodyTop + 6);
          cv.Rectangle(x2 - 6, bodyTop, x2, bodyTop + 6);
        end;
      end;

      { trim-edge hover handles - thin bright strips at each end, echoing the
        ~6px hit zone used by TlHitTestClipEdge }
      cv.Pen.Color := theme.Border;
      VLine(x + 2, top + 3, top + laneH - 3, theme.Border);
      VLine(x2 - 2, top + 3, top + laneH - 3, theme.Border);
    end;
    end;
  finally
    RestoreDC(cv.Handle, clipSave);
  end;

  { ---- playhead: bold, bright accent line with a drop-triangle on the ruler -
    3px wide (not the hairline every other line in this paint uses) so it
    reads clearly against the grid/waveforms/clip borders at any zoom level,
    matching a real DAW's transport cursor rather than blending into the
    background. }
  playX := FTlView.SecondsToX(tl.PlayheadSeconds);
  if (playX >= FTlView.HeaderWidth) and (playX <= w) then
  begin
    cv.Pen.Width := 3;
    VLine(Round(playX), 0, h, theme.Accent);
    cv.Pen.Width := 1;
    cv.Brush.Color := theme.Accent;
    cv.Pen.Color := theme.Accent;
    cv.Polygon([Point(Round(playX) - 6, 0), Point(Round(playX) + 6, 0), Point(Round(playX), 10)]);
  end;

  { ---- range/section selection: dashed boundary lines spanning every
    track, drawn last so they stay visible over clip bodies/waveforms. ---- }
  if FTlRangeActive then
  begin
    rngX1 := FTlView.SecondsToX(FTlRangeStartSec);
    rngX2 := FTlView.SecondsToX(FTlRangeEndSec);
    if (rngX2 >= FTlView.HeaderWidth) and (rngX1 <= w) then
    begin
      cv.Pen.Style := psDash;
      if rngX1 >= FTlView.HeaderWidth then VLine(Round(rngX1), FTlView.RulerHeight, h, theme.Selection);
      if rngX2 <= w then VLine(Round(rngX2), FTlView.RulerHeight, h, theme.Selection);
      cv.Pen.Style := psSolid;
    end;
  end;

  { ---- rubber-band selection rectangle ---- }
  if FTlRubberSelecting then
  begin
    cv.Brush.Style := bsClear;
    cv.Pen.Color := theme.Accent;
    cv.Pen.Style := psDash;
    cv.Rectangle(FTlRubberStartX, FTlRubberStartY, FTlRubberX, FTlRubberY);
    cv.Pen.Style := psSolid;
    cv.Brush.Style := bsSolid;
  end;
  end;

  pbTimeline.Canvas.Draw(0, 0, FTlBuffer);
end;

{ Fast attack / slow release ballistics for FTlMeterL/R, called once per UI
  tick (~30fps) while FTlPlaying - jumping straight to a new peak reads as a
  flicker on a bar graph, so releases decay 15%/tick instead of snapping to
  the next (possibly much lower) instantaneous peak. }
procedure TfrmMain.UpdateTimelineMeterChannel(var AMeter: Single; APeak: Single);
begin
  if APeak > 1 then APeak := 1
  else if APeak < 0 then APeak := 0;
  if APeak > AMeter then AMeter := APeak
  else AMeter := AMeter * 0.85;
end;

{ Timeline "Out L"/"Out R" level graphs (pbTlMeters, next to the master-vol
  slider). FTlMeterL/FTlMeterR are updated once per UI tick while FTlPlaying
  (see the tmrUITimer block) and pinned to 0 by StopTimelinePlayback, so this
  only moves during playback and goes flat the instant it stops. Painted
  into FTlMeterBuffer and blitted in one shot - the same double-buffer +
  csOpaque trick pbTimelinePaint/pbMixerPaint use - so the 30fps invalidate
  during playback never flickers. }
procedure TfrmMain.pbTlMetersPaint(Sender: TObject);
const
  LABEL_W = 16;
  SEGMENT_COUNT = 20;
  SEGMENT_W = 3;
  SEGMENT_GAP = 1;
  UNLIT_COLOR = $00303030;
var
  cv: TCanvas;
  w, h, barH, gap, y: Integer;

  { Classic LED-ladder meter: a FIXED-size gauge - exactly SEGMENT_COUNT
    (20) blocks, each exactly SEGMENT_W (3) px wide, never stretched to
    fill whatever width pbTlMeters happens to have. Any leftover control
    width past the fixed gauge just stays black, so resizing the header
    never distorts the block size back into unreadable slivers. }
  procedure DrawBar(const ALabel: string; ALevel: Single; AY: Integer);
  var
    litCount, i, segX0, segX1: Integer;
    segColor: TColor;
  begin
    cv.Brush.Style := bsClear;
    cv.Font.Color := clSilver;
    cv.TextOut(0, AY + (barH - cv.TextHeight(ALabel)) div 2, ALabel);

    litCount := Round(ALevel * SEGMENT_COUNT);
    cv.Pen.Style := psClear;
    cv.Brush.Style := bsSolid;
    for i := 0 to SEGMENT_COUNT - 1 do
    begin
      segX0 := LABEL_W + i * (SEGMENT_W + SEGMENT_GAP);
      segX1 := segX0 + SEGMENT_W;
      if i < litCount then
      begin
        if i >= SEGMENT_COUNT - 2 then segColor := clRed
        else if i >= SEGMENT_COUNT - 5 then segColor := clYellow
        else segColor := clLime;
      end
      else
        segColor := UNLIT_COLOR;
      cv.Brush.Color := segColor;
      cv.Rectangle(segX0, AY, segX1, AY + barH);
    end;
    cv.Pen.Style := psSolid;
  end;

begin
  w := pbTlMeters.Width;
  h := pbTlMeters.Height;
  if (w <= 0) or (h <= 0) then Exit;
  FTlMeterBuffer.SetSize(w, h);
  cv := FTlMeterBuffer.Canvas;
  cv.Brush.Color := clBlack;
  cv.Brush.Style := bsSolid;
  cv.FillRect(Rect(0, 0, w, h));

  gap := 2;
  barH := (h - gap) div 2;
  if barH > 0 then
  begin
    y := 0;
    DrawBar('L', FTlMeterL, y);
    Inc(y, barH + gap);
    DrawBar('R', FTlMeterR, y);
  end;

  pbTlMeters.Canvas.Draw(0, 0, FTlMeterBuffer);
end;

{ One master-output spectrum (log frequency, 0..-90 dB) filling ARect - the
  Timeline's header-column corner. Follows the mixer because the tap is the
  engine's post-mixer output. Flat while not playing. }
procedure TfrmMain.DrawTimelineSpectrum(ACanvas: TCanvas; const ARect: TRect);
const
  MIN_HZ = 30.0;
  TOP_DB = 0.0;
  BOT_DB = -90.0;
var
  w, h, x, n, bin, prevBin, b: Integer;
  nyq, hz0, hz1, db, mx: Double;
begin
  w := ARect.Right - ARect.Left;
  h := ARect.Bottom - ARect.Top;
  if (w < 8) or (h < 4) then Exit;
  ACanvas.Brush.Color := clBlack;
  ACanvas.Brush.Style := bsSolid;
  ACanvas.FillRect(ARect);
  n := Length(FTlSpecDb);
  if (not FTlSpecActive) or (n < 2) or (FTlSpecRate <= 0) then Exit;
  nyq := FTlSpecRate / 2;
  ACanvas.Pen.Style := psSolid;
  ACanvas.Pen.Color := clLime;
  prevBin := 0;
  for x := 0 to w - 1 do
  begin
    hz0 := MIN_HZ * Exp(Ln(nyq / MIN_HZ) * x / w);
    hz1 := MIN_HZ * Exp(Ln(nyq / MIN_HZ) * (x + 1) / w);
    bin := Round(hz0 / nyq * (n - 1));
    b := Round(hz1 / nyq * (n - 1));
    if bin < prevBin then bin := prevBin;
    if b < bin then b := bin;
    if b > n - 1 then b := n - 1;
    if bin > n - 1 then bin := n - 1;
    mx := BOT_DB;
    for prevBin := bin to b do
    begin
      db := FTlSpecDb[prevBin];
      if db > mx then mx := db;
    end;
    prevBin := b;
    if mx > TOP_DB then mx := TOP_DB;
    b := Round((mx - BOT_DB) / (TOP_DB - BOT_DB) * (h - 1));
    if b > 0 then
    begin
      ACanvas.MoveTo(ARect.Left + x, ARect.Bottom - 1);
      ACanvas.LineTo(ARect.Left + x, ARect.Bottom - 1 - b);
    end;
  end;
end;

function SlicePlanarLocal(const ASrc: TAudioPlanar; AStart, ACount: Integer): TAudioPlanar;
var
  ch, i: Integer;
begin
  SetLength(Result, Length(ASrc));
  for ch := 0 to High(ASrc) do
  begin
    SetLength(Result[ch], ACount);
    for i := 0 to ACount - 1 do
      Result[ch][i] := ASrc[ch][AStart + i];
  end;
end;

{ Live recording: the audio callback feeds a bounded ring; the dedicated writer
  drains and finalizes the take before the UI commits it to the timeline. }

function TfrmMain.BuildRecordSettings: TRecordSettings;
begin
  Result := TRecordSettings.Default;
  Result.SampleRate := App.Audio.Granted.SampleRate;
  Result.Channels := App.Audio.Granted.CaptureChannels;
  if Result.Channels = 1 then Result.ChannelMode := rcmMono
  else if Result.Channels = 2 then Result.ChannelMode := rcmStereo
  else Result.ChannelMode := rcmMultichannel;
  case cboRecFormat.ItemIndex of
    1: Result.TakeFormat := wsfPCM24;
    2: Result.TakeFormat := wsfPCM16;
  else Result.TakeFormat := wsfFloat32;
  end;

  Result.InputMonitoring := chkRecMonitor.Checked;
  Result.MonitorGainDb := 0;

  Result.PreRollSeconds := Max(0, StrToFloatDef(Trim(edtRecPreRoll.Text), 0));
  Result.CountInBeats := Max(0, StrToIntDef(Trim(edtRecCountIn.Text), 0));
  if FProject <> nil then Result.TempoBPM := FProject.TempoBPM
  else Result.TempoBPM := 120;

  case cboRecPunch.ItemIndex of
    1: Result.PunchMode := pmPunchIn;
    2: Result.PunchMode := pmPunchInOut;
  else Result.PunchMode := pmOff;
  end;
  Result.PunchInSeconds := Max(0, StrToFloatDef(Trim(edtRecPunchIn.Text), 0));
  Result.PunchOutSeconds := Max(0, StrToFloatDef(Trim(edtRecPunchOut.Text), 0));

  Result.LoopRecord := chkRecLoop.Checked;
  Result.LoopStartSeconds := Max(0, StrToFloatDef(Trim(edtRecLoopStart.Text), 0));
  Result.LoopEndSeconds := Max(0, StrToFloatDef(Trim(edtRecLoopEnd.Text), 0));

  Result.Validate;
end;

function TfrmMain.RecordingRootPath: string;
begin
  Result := Trim(App.Config.GetString(CFG_SEC_PATHS, CFG_PATH_RECORDINGS, ''));
  { Recorded/generated audio is real user content that outlives the session -
    it must not default into Cache, which the OS or a cleanup tool can
    legitimately purge out from under a project that still references it. }
  if Result = '' then Result := IncludeTrailingPathDelimiter(App.Paths.Data) + 'recordings';
end;

function TfrmMain.RecordingPosition: Double;
begin
  Result := 0;
  if FProject = nil then Exit;
  if FTlRangeActive then Result := Max(0, FTlRangeStartSec)
  else Result := Max(0, FRecInsertSeconds);
end;

procedure TfrmMain.cboRecPunchChange(Sender: TObject);
var
  on_: Boolean;
begin
  on_ := cboRecPunch.ItemIndex > 0;
  edtRecPunchIn.Enabled := on_;
  edtRecPunchOut.Enabled := cboRecPunch.ItemIndex = 2;
end;

procedure TfrmMain.chkRecLoopClick(Sender: TObject);
begin
  edtRecLoopStart.Enabled := chkRecLoop.Checked;
  edtRecLoopEnd.Enabled := chkRecLoop.Checked;
end;

procedure TfrmMain.btnRecArmClick(Sender: TObject);
var
  settings: TRecordSettings;
begin
  if FRecWriter <> nil then
  begin
    StopLiveRecording;
    Exit;
  end;
  if (App = nil) or (App.Audio = nil) or (FProject = nil) then Exit;
  if (FRec.TakeCount > 0) and not FRecCommitted then
  begin
    MessageDlg('Add the pending take to the timeline before starting another recording.', mtInformation, [mbOK], 0);
    Exit;
  end;
  try
    if (App.Audio.Granted.CaptureChannels <= 0) or
       (Pos('software', LowerCase(App.Audio.BackendName)) > 0) then
      RaiseUDAW(errInvalidState, 'Recording',
        'Select a real input device and enable capture in Settings, then reopen Audio.');
    if App.Audio.State <> aesRunning then App.Audio.Start;
    if App.Audio.State <> aesRunning then
      RaiseUDAW(errInvalidState, 'Recording', 'The input device is not running.');
    if FTlPlaying then btnTlStopClick(nil);
    settings := BuildRecordSettings;
    App.Audio.Stop;
    FRec.Disarm;
    if not SameText(FRec.RecordingRoot, RecordingRootPath) then
    begin
      FreeAndNil(FRec);
      FRec := TRecordingEngine.Create(RecordingRootPath);
      FreeAndNil(FRecovery2);
      FRecovery2 := TRecordingRecovery.Create(RecordingRootPath);
    end;
    FRec.ClearTakes;
    FRec.Configure(settings);
    FRec.Arm;
    FRecTrackId := Max(0, TlSelectedAudioTrackId);
    FRecCommitted := False;
    FRec.Start(RecordingPosition);
    FRecRing := TAudioRing.Create(settings.Channels, settings.SampleRate * 4);
    FRecWriter := TRecordingWriterThread.Create(FRec, FRecRing);
    App.Audio.SetCaptureRing(FRecRing);
    App.Audio.SetInputMonitoring(settings.InputMonitoring, settings.MonitorGainDb);
    FRecStarted := GetTickCount64;
    FSyncProgressActive := True;
    App.Audio.Start;
    if App.Audio.State <> aesRunning then
      RaiseUDAW(errInvalidState, 'Recording', 'Could not start the input device.');
    RefreshRecordingTab;
  except
    on E: Exception do
    begin
      if FRecWriter <> nil then StopLiveRecording
      else FreeAndNil(FRecRing);
      FSyncProgressActive := False;
      memRec.Lines.Text := 'Recording failed: ' + E.Message;
      MessageDlg(memRec.Lines.Text, mtError, [mbOK], 0);
    end;
  end;
end;

procedure TfrmMain.StopLiveRecording;
var
  captureError: string;
  overruns: Integer;
begin
  if FRecWriter = nil then Exit;
  captureError := '';
  App.Audio.Stop; { quiesce producer before final drain and ring release }
  App.Audio.SetCaptureRing(nil);
  App.Audio.SetInputMonitoring(False);
  ShowStatusProgress('Finishing recording: draining and saving complete audio...', 3);
  try
    FRecWriter.Stop;
    captureError := FRecWriter.LastError;
    overruns := FRecWriter.RingOverruns;
    if overruns > 0 then
      captureError := captureError + Format(' Capture buffer overflow (%d); audio was lost.', [overruns]);
    FreeAndNil(FRecWriter);
    FreeAndNil(FRecRing);
    UpdateStatusProgress(1, 'Finishing recording: saving complete take...');
    UpdateStatusProgress(2, 'Adding recording to the timeline...');
    if FRec.TakeCount > 0 then btnRecCommitClick(nil)
    else if App.Audio.CaptureMismatchCount > 0 then
      captureError := captureError + Format(
        ' No audio frames were received: the input device''s channel count changed ' +
        'after arming (%d block(s) dropped) - re-arm the recording.', [App.Audio.CaptureMismatchCount])
    else
      captureError := captureError + ' No audio frames were received.';
    UpdateStatusProgress(3, 'Recording saved.');
  except
    on E: Exception do captureError := captureError + ' ' + E.Message;
  end;
  HideStatusProgress;
  RefreshRecordingTab;
  if captureError <> '' then
  begin
    memRec.Lines.Insert(0, 'Recording needs attention: ' + captureError);
    Logger.Error('Recording', captureError);
    MessageDlg('Recording needs attention: ' + captureError, mtWarning, [mbOK], 0);
  end;
  App.Audio.Start;
end;

procedure TfrmMain.btnRecSavedClick(Sender: TObject);
var
  trackId: Integer;
begin
  if (FRecWriter <> nil) or (FProject = nil) then Exit;
  dlgRecSaved.InitialDir := RecordingRootPath;
  if not dlgRecSaved.Execute then Exit;
  trackId := TlSelectedAudioTrackId;
  if trackId < 0 then trackId := TlNewAudioTrackId;
  if ImportBrowserFileToTimeline(dlgRecSaved.FileName, trackId, RecordingPosition) then
    RefreshTimelineTab
  else MessageDlg('Audio could not be imported. See the Timeline readout for details.', mtError, [mbOK], 0);
end;

procedure TfrmMain.btnRecCommitClick(Sender: TObject);
var
  lane: TTakeLane;
  comp: TTakeComp;
  cmd: TCommitTakeCommand;
  clip: TTimelineClip;
  specs: TRecordedClipSpecArray;
  i: Integer;
begin
  if (FRec = nil) or (FProject = nil) or (FRecWriter <> nil) or FRecCommitted then Exit;
  if FRec.TakeCount = 0 then
  begin
    memRec.Lines.Insert(0, 'record a take first');
    Exit;
  end;
  lane := TTakeLane.Create('Recorded');
  comp := nil;
  try
    for i := 0 to FRec.TakeCount - 1 do
      lane.AddTake(FRec.GetTake(i));
    comp := TTakeComp.Create(lane);
    { commit every take as its own clip so stacked loop passes are all visible }
    SetLength(specs, FRec.TakeCount);
    for i := 0 to FRec.TakeCount - 1 do
    begin
      specs[i].SourceWavFile := FRec.GetTake(i).WavFile;
      specs[i].SampleRate := FRec.GetTake(i).SampleRate;
      specs[i].Channels := FRec.GetTake(i).Channels;
      specs[i].SourceFrameCount := FRec.GetTake(i).FrameCount;
      specs[i].Name := FRec.GetTake(i).Name;
      specs[i].TimelineStartSeconds := FRec.GetTake(i).TimelineStartSeconds;
      specs[i].SourceOffsetSeconds := 0;
      specs[i].LengthSeconds := FRec.GetTake(i).LengthSeconds;
    end;
    cmd := TCommitTakeCommand.Create(FProject, FRecTrackId, specs, 'Recorded');
    FCmds.Perform(cmd);
    FRecCommitted := True;
    if Length(cmd.ClipIds) > 0 then
    begin
      TlSetSingleSelection(cmd.ClipIds[0]);
      clip := FProject.Timeline.ClipById(cmd.ClipIds[0]);
      if clip <> nil then
      begin
        if cmd.CreatedTrackId > 0 then FTlSelectedTrackId := cmd.CreatedTrackId
        else FTlSelectedTrackId := FRecTrackId;
        FTlView.EnsureVisible(clip.StartSeconds);
        WarmClipWaveform(clip.SourceId);
      end;
    end;
    Logger.Info('ui', Format('committed %d recorded clip(s) to the timeline', [Length(specs)]));
    RefreshRecordingTab;
    RefreshTimelineTab;
  finally
    comp.Free;
    lane.Free;
  end;
end;

{ Copies the selected take's own WAV file to a user-chosen path - independent
  of the timeline entirely. A plain stream copy, not a re-encode: the take's
  WavFile is already a complete, valid WAV written by the recording engine. }
procedure TfrmMain.btnRecSaveTakeClick(Sender: TObject);
var
  idx: Integer;
  tk: TRecordedTake;
  src, dst: TFileStream;
begin
  if not RequireRegistration('Exporting a recorded take') then Exit;
  if (FRec = nil) or (FRecWriter <> nil) then Exit;
  idx := RecSelectedTakeIndex;
  if idx < 0 then
  begin
    memRec.Lines.Insert(0, 'Select a take above first.');
    Exit;
  end;
  tk := FRec.GetTake(idx);
  if (tk.WavFile = '') or not FileExists(tk.WavFile) then
  begin
    memRec.Lines.Insert(0, 'Selected take has no recorded audio file to save.');
    Exit;
  end;
  dlgRecSaveTake.InitialDir := RecordingRootPath;
  dlgRecSaveTake.FileName := tk.Name;
  if not dlgRecSaveTake.Execute then Exit;
  try
    src := TFileStream.Create(tk.WavFile, fmOpenRead or fmShareDenyWrite);
    try
      dst := TFileStream.Create(dlgRecSaveTake.FileName, fmCreate);
      try
        dst.CopyFrom(src, 0);
      finally
        dst.Free;
      end;
    finally
      src.Free;
    end;
    memRec.Lines.Insert(0, 'Saved take to: ' + dlgRecSaveTake.FileName);
  except
    on E: Exception do
      memRec.Lines.Insert(0, 'Save FAILED: ' + E.Message);
  end;
end;

{ Adds just the selected take to the timeline as its own clip, at the take's
  own TimelineStartSeconds (the position it was actually captured at) - unlike
  btnRecCommitClick, which commits every take in the current session at once. }
procedure TfrmMain.btnRecAddTakeToTimelineClick(Sender: TObject);
var
  idx, trackId: Integer;
  tk: TRecordedTake;
begin
  if (FRec = nil) or (FProject = nil) or (FRecWriter <> nil) then Exit;
  idx := RecSelectedTakeIndex;
  if idx < 0 then
  begin
    memRec.Lines.Insert(0, 'Select a take above first.');
    Exit;
  end;
  tk := FRec.GetTake(idx);
  if (tk.WavFile = '') or not FileExists(tk.WavFile) then
  begin
    memRec.Lines.Insert(0, 'Selected take has no recorded audio file to add.');
    Exit;
  end;
  trackId := FRecTrackId;
  if trackId <= 0 then trackId := TlSelectedAudioTrackId;
  if trackId < 0 then trackId := TlNewAudioTrackId;
  if ImportBrowserFileToTimeline(tk.WavFile, trackId, tk.TimelineStartSeconds) then
  begin
    memRec.Lines.Insert(0, Format('Added take "%s" to the timeline at %.3f s.',
      [tk.Name, tk.TimelineStartSeconds]));
    RefreshTimelineTab;
  end
  else
    memRec.Lines.Insert(0, 'Add to timeline FAILED. See the Timeline readout for details.');
end;

procedure TfrmMain.btnRecScanClick(Sender: TObject);
var
  pending, recovered: TRecordedTakeArray;
  outDir: string;
  i: Integer;
begin
  if (FRecovery2 = nil) or (FRecWriter <> nil) then Exit;
  FreeAndNil(FRecovery2);
  FRecovery2 := TRecordingRecovery.Create(RecordingRootPath);
  pending := FRecovery2.ScanUnfinished;
  if Length(pending) = 0 then
  begin
    memRec.Lines.Text := 'No unfinished takes found - nothing to recover.';
    Exit;
  end;
  outDir := IncludeTrailingPathDelimiter(RecordingRootPath) + 'Recovered';
  recovered := FRecovery2.RecoverAll(outDir);
  memRec.Lines.Clear;
  memRec.Lines.Add(Format('Recovered %d unfinished take(s) into:', [Length(recovered)]));
  memRec.Lines.Add('  ' + outDir);
  for i := 0 to High(recovered) do
    memRec.Lines.Add('  ' + recovered[i].Describe);
  Logger.Info('ui', Format('recording recovery: %d take(s) rebuilt', [Length(recovered)]));
end;

procedure TfrmMain.RefreshRecordingTab;
var
  sb: TStringBuilder;
  i: Integer;
begin
  if FRec = nil then Exit;
  if (App <> nil) and (App.Audio <> nil) and
     (App.Audio.State = aesRunning) and (App.Audio.Granted.CaptureChannels > 0) and
     (Pos('software', LowerCase(App.Audio.BackendName)) = 0) then
  begin
    if FRecWriter <> nil then
      lblRecMicState.Caption := 'Microphone: ON | Recording: ON'
    else
      lblRecMicState.Caption := 'Microphone: ON | Recording: OFF';
    lblRecMicState.Hint := App.Audio.Granted.CaptureDeviceName;
  end
  else
    lblRecMicState.Caption := 'Microphone: OFF | Recording: OFF';
  btnRecSaved.Enabled := FRecWriter = nil;
  btnRecScan.Enabled := FRecWriter = nil;
  cboRecFormat.Enabled := FRecWriter = nil;
  cboRecPunch.Enabled := FRecWriter = nil;
  chkRecLoop.Enabled := FRecWriter = nil;
  chkRecMonitor.Enabled := FRecWriter = nil;
  edtRecPreRoll.Enabled := FRecWriter = nil;
  edtRecCountIn.Enabled := FRecWriter = nil;
  if FRecWriter = nil then
  begin
    { restore each edit's own enabled state from its combo/checkbox, rather
      than force-enabling ones that should stay greyed out (e.g. punch-out
      when punch mode is "Punch-in" only). }
    cboRecPunchChange(nil);
    chkRecLoopClick(nil);
  end
  else
  begin
    edtRecPunchIn.Enabled := False;
    edtRecPunchOut.Enabled := False;
    edtRecLoopStart.Enabled := False;
    edtRecLoopEnd.Enabled := False;
  end;
  if FRecWriter <> nil then
  begin
    btnRecArm.Caption := 'Stop and add to timeline';
    mnuRecArm.Caption := btnRecArm.Caption;
    pmRecArm.Caption := btnRecArm.Caption;
    btnRecCommit.Enabled := False;
    mnuRecCommit.Enabled := False;
    pmRecCommit.Enabled := False;
    btnRecSaveTake.Enabled := False;
    btnRecAddTakeToTimeline.Enabled := False;
    lblRecDestination.Caption := Format('Capturing %.1f s | %d Hz | %d channels | target track %d',
      [FRecWriter.FramesConsumed / FRec.Settings.SampleRate, FRec.Settings.SampleRate,
       FRec.Settings.Channels, FRecTrackId]);
    stbMain.SimpleText := lblRecDestination.Caption;
    Exit; { no access to takes while the writer owns the engine }
  end;
  btnRecArm.Caption := 'Start live recording';
  mnuRecArm.Caption := btnRecArm.Caption;
  pmRecArm.Caption := btnRecArm.Caption;
  lblRecDestination.Caption := Format('Insert at %.3f s. Selected audio track, or a new track. Full input until Stop.', [RecordingPosition]);
  mnuRecCommit.Enabled := (FRec.TakeCount > 0) and not FRecCommitted;
  btnRecCommit.Enabled := mnuRecCommit.Enabled;
  pmRecCommit.Enabled := mnuRecCommit.Enabled;
  btnRecSaveTake.Enabled := RecSelectedTakeIndex >= 0;
  btnRecAddTakeToTimeline.Enabled := btnRecSaveTake.Enabled;

  sb := TStringBuilder.Create;
  try
    sb.AppendLine(FRec.Describe);
    if (FRecovery2 <> nil) and FRecovery2.HasUnfinishedTakes then
      sb.AppendLine(#10'** unfinished take container(s) present - press "Scan for recovery" **');
    if FProject <> nil then
    begin
      sb.AppendLine('');
      sb.AppendLine(Format('project timeline: %d track(s), %d clip(s)',
        [FProject.Timeline.TrackCount, FProject.Timeline.ClipCountTotal]));
    end;
    for i := 0 to FRec.TakeCount - 1 do
      if FRec.GetTake(i).WavFile <> '' then
        sb.AppendLine('  wav: ' + FRec.GetTake(i).WavFile);
    memRec.Lines.Text := sb.ToString;
  finally
    sb.Free;
  end;
  pbRecTakes.Invalidate;
end;

{ Paints into FRecBuffer and blits it in one shot instead of drawing every
  take rectangle straight to the screen DC - this box is invalidated at
  near-frame rate by tmrUI while recording (see RefreshRecordingTab), and
  drawing directly flickered badly; mirrors pbTimelinePaint/FTlBuffer and
  pbMixerPaint/FMixBuffer. FRecTakeRects/FRecTakeIds are rebuilt on every
  paint so pbRecTakesMouseDown can hit-test a click against the take actually
  on screen right now, exactly like FMixStripRects. }
procedure TfrmMain.pbRecTakesPaint(Sender: TObject);
var
  cv: TCanvas;
  w, h, i, y, x1, x2: Integer;
  span, s: Double;
  tk: TRecordedTake;
  selected: Boolean;
begin
  w := pbRecTakes.Width;
  h := pbRecTakes.Height;
  if (w <= 0) or (h <= 0) then Exit;
  FRecBuffer.SetSize(w, h);
  cv := FRecBuffer.Canvas;
  cv.Brush.Color := $00202020;
  cv.Brush.Style := bsSolid;
  cv.FillRect(Rect(0, 0, w, h));
  SetLength(FRecTakeRects, 0);
  SetLength(FRecTakeIds, 0);
  if FRecWriter <> nil then
  begin
    pbRecTakes.Canvas.Draw(0, 0, FRecBuffer);
    Exit;
  end;
  if (FRec = nil) or (FRec.TakeCount = 0) then
  begin
    cv.Brush.Style := bsClear;
    cv.Font.Color := $00A0A0A0;
    cv.TextOut(10, 10, 'Select a timeline destination, then start live recording or add saved audio.');
    pbRecTakes.Canvas.Draw(0, 0, FRecBuffer);
    Exit;
  end;

  span := 1.0;
  for i := 0 to FRec.TakeCount - 1 do
  begin
    tk := FRec.GetTake(i);
    s := tk.TimelineStartSeconds + tk.LengthSeconds;
    if s > span then span := s;
  end;
  span := span * 1.05;

  cv.Brush.Style := bsClear;
  cv.Font.Color := $00808080;
  cv.TextOut(4, 2, Format('0 s', []));
  cv.TextOut(w - 48, 2, Format('%.2f s', [span]));

  { Ctrl+drag highlighted region, behind the takes }
  if FRecRegionActive then
  begin
    cv.Brush.Style := bsSolid;
    cv.Brush.Color := $00584838;
    cv.FillRect(Rect(Min(FRecRegionX0, FRecRegionX1), 0,
      Max(FRecRegionX0, FRecRegionX1), h));
  end;

  SetLength(FRecTakeRects, FRec.TakeCount);
  SetLength(FRecTakeIds, FRec.TakeCount);
  for i := 0 to FRec.TakeCount - 1 do
  begin
    tk := FRec.GetTake(i);
    FRecTakeIds[i] := tk.Id;
    y := 22 + i * 26;
    if y > h - 52 then
    begin
      FRecTakeRects[i] := Rect(0, 0, 0, 0);
      Continue;
    end;
    x1 := Round(tk.TimelineStartSeconds / span * (w - 12)) + 6;
    x2 := Round((tk.TimelineStartSeconds + tk.LengthSeconds) / span * (w - 12)) + 6;
    if x2 <= x1 then x2 := x1 + 1;
    FRecTakeRects[i] := Rect(x1, y, x2, y + 20);
    selected := (FRecSelectedTakeId <> '') and (tk.Id = FRecSelectedTakeId);
    cv.Brush.Style := bsSolid;
    if selected then cv.Brush.Color := $006A8AC0 else cv.Brush.Color := $00505A78;
    cv.Pen.Color := IfThen(selected, $00D0E0FF, $0090A8D0);
    cv.Pen.Width := IfThen(selected, 2, 1);
    cv.Rectangle(x1, y, x2, y + 20);
    cv.Pen.Width := 1;
    cv.Brush.Style := bsClear;
    cv.Font.Color := $00F0F0F0;
    cv.TextOut(x1 + 4, y + 3, Format('%s  (%.2f s, pass %d)',
      [tk.Name, tk.LengthSeconds, tk.PassIndex]));
  end;
  { comp lane (the swipe-comp result) and the swipe in progress }
  EnsureComp;
  FRecSpan := span;
  if FComp <> nil then
  begin
    y := h - 26;
    cv.Brush.Style := bsClear;
    cv.Font.Color := $00A0A0A0;
    cv.TextOut(4, y - 16, 'Comp (swipe across a take to choose it for that stretch):');
    for i := 0 to FComp.SegmentCount - 1 do
    begin
      x1 := Round(FComp.GetSegment(i).StartSeconds / span * (w - 12)) + 6;
      x2 := Round(FComp.GetSegment(i).EndSeconds / span * (w - 12)) + 6;
      if x2 <= x1 then x2 := x1 + 1;
      cv.Brush.Style := bsSolid;
      cv.Brush.Color := TColor($00405060 + (FComp.GetSegment(i).TakeIndex mod 5) * $00181008);
      cv.Pen.Color := $0090D0A0;
      cv.Rectangle(x1, y, x2, y + 20);
      cv.Brush.Style := bsClear;
      cv.Font.Color := $00F0F0F0;
      cv.TextOut(x1 + 4, y + 3, Format('take %d', [FComp.GetSegment(i).TakeIndex + 1]));
    end;
  end;
  if FCompSwipeOn then
  begin
    cv.Brush.Style := bsClear;
    cv.Pen.Color := $0040E0FF;
    cv.Pen.Width := 2;
    cv.Rectangle(Min(FCompSwipeX0, FCompSwipeX1), 20, Max(FCompSwipeX0, FCompSwipeX1), h - 4);
    cv.Pen.Width := 1;
  end;
  pbRecTakes.Canvas.Draw(0, 0, FRecBuffer);
end;

{ Click-to-select a take, so "Save Selected Take As..." / "Add Selected Take
  to Timeline" have something to act on. Clicking empty space clears the
  selection, matching the Mixer strip picker's click-to-select/click-away
  behaviour. }
procedure TfrmMain.pbRecTakesMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  i: Integer;
  hit: string;
begin
  hit := '';
  FCompSwipeOn := False;
  FRecRegionActive := False;
  if (Button = mbLeft) and (ssCtrl in Shift) then
  begin
    FRecRegionDragging := True;
    FRecRegionX0 := X;
    FRecRegionX1 := X;
    pbRecTakes.Invalidate;
    Exit;
  end;
  for i := 0 to High(FRecTakeRects) do
    if PtInRect(FRecTakeRects[i], Point(X, Y)) then
    begin
      hit := FRecTakeIds[i];
      { start a comp swipe on this take row }
      FCompSwipeOn := True;
      FCompSwipeTake := i;
      FCompSwipeX0 := X;
      FCompSwipeX1 := X;
      Break;
    end;
  if hit <> FRecSelectedTakeId then
  begin
    FRecSelectedTakeId := hit;
    RefreshRecordingTab;
  end;
end;

{ ---- Comping: swipe across a take row to make that stretch of the comp play
  from that take (Pro-Tools/Logic style), see UDAW.Recording.Takes.TTakeComp.
  The comp lane is drawn under the takes; "Commit Comp to Timeline" turns the
  comp into one undoable clip per segment. }
procedure TfrmMain.EnsureComp;
var
  i: Integer;
begin
  if (FRec = nil) or (FRec.TakeCount = 0) then
  begin
    FreeAndNil(FComp);
    FreeAndNil(FCompLane);
    FCompTakeCount := 0;
    Exit;
  end;
  if (FComp <> nil) and (FCompTakeCount = FRec.TakeCount) then Exit;
  FreeAndNil(FComp);
  FreeAndNil(FCompLane);
  FCompLane := TTakeLane.Create('Comp');
  for i := 0 to FRec.TakeCount - 1 do
    FCompLane.AddTake(FRec.GetTake(i));
  FComp := TTakeComp.Create(FCompLane);
  FCompTakeCount := FRec.TakeCount;
end;

function TfrmMain.RecXToSeconds(X: Integer): Double;
begin
  if pbRecTakes.Width <= 12 then Exit(0);
  Result := (X - 6) / (pbRecTakes.Width - 12) * FRecSpan;
end;

procedure TfrmMain.pbRecTakesMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
begin
  if FRecRegionDragging then
  begin
    FRecRegionX1 := X;
    FRecRegionActive := Abs(FRecRegionX1 - FRecRegionX0) >= 3;
    pbRecTakes.Invalidate;
    Exit;
  end;
  if FCompSwipeOn then
  begin
    FCompSwipeX1 := X;
    pbRecTakes.Invalidate;
  end;
end;

procedure TfrmMain.pbRecTakesMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  t0, t1: Double;
begin
  if FRecRegionDragging then
  begin
    FRecRegionDragging := False;
    Exit;
  end;
  if not FCompSwipeOn then Exit;
  FCompSwipeOn := False;
  FCompSwipeX1 := X;
  if Abs(FCompSwipeX1 - FCompSwipeX0) >= 6 then
  begin
    EnsureComp;
    if FComp <> nil then
    begin
      t0 := RecXToSeconds(Min(FCompSwipeX0, FCompSwipeX1));
      t1 := RecXToSeconds(Max(FCompSwipeX0, FCompSwipeX1));
      FComp.SetActiveTake(t0, t1, FCompSwipeTake);
      memRec.Lines.Insert(0, Format('Comp: %.2f-%.2f s now plays from take %d.',
        [t0, t1, FCompSwipeTake + 1]));
    end;
  end;
  pbRecTakes.Invalidate;
end;

procedure TfrmMain.btnRecResetCompClick(Sender: TObject);
begin
  EnsureComp;
  if FComp <> nil then
  begin
    FComp.Reset;
    memRec.Lines.Insert(0, 'Comp reset to take 1 for the whole lane.');
  end;
  pbRecTakes.Invalidate;
end;

procedure TfrmMain.btnRecCommitCompClick(Sender: TObject);
var
  specs: TRecordedClipSpecArray;
  i, trackId: Integer;
  tl: TTimeline;
  src: TMediaSource;
  srcIds: TDictionary<string, Integer>;
  srcId: Integer;
begin
  if (FRec = nil) or (FProject = nil) or (FRecWriter <> nil) then Exit;
  EnsureComp;
  if FComp = nil then
  begin
    memRec.Lines.Insert(0, 'Comp: no takes to comp yet.');
    Exit;
  end;
  specs := FComp.FlattenToClipSpecs;
  if Length(specs) = 0 then
  begin
    memRec.Lines.Insert(0, 'Comp: no segment has a recorded audio file.');
    Exit;
  end;
  trackId := FRecTrackId;
  if trackId <= 0 then trackId := TlSelectedAudioTrackId;
  if trackId < 0 then trackId := TlNewAudioTrackId;
  tl := FProject.Timeline;
  srcIds := TDictionary<string, Integer>.Create;
  try
    for i := 0 to High(specs) do
    begin
      if not srcIds.TryGetValue(specs[i].SourceWavFile, srcId) then
      begin
        src := tl.AddSource(specs[i].SourceWavFile, specs[i].SampleRate,
          specs[i].Channels, specs[i].SourceFrameCount);
        srcId := src.Id;
        srcIds.Add(specs[i].SourceWavFile, srcId);
      end;
      FCmds.Perform(TAddTimelineClipCommand.Create(FProject, trackId, srcId,
        specs[i].Name, specs[i].TimelineStartSeconds, specs[i].SourceOffsetSeconds,
        specs[i].LengthSeconds));
    end;
  finally
    srcIds.Free;
  end;
  memRec.Lines.Insert(0, Format('Comp committed: %d clip(s) added to the timeline (undoable).', [Length(specs)]));
  RefreshTimelineTab;
end;

function TfrmMain.RecSelectedTakeIndex: Integer;
var
  i: Integer;
begin
  Result := -1;
  if (FRec = nil) or (FRecSelectedTakeId = '') then Exit;
  for i := 0 to FRec.TakeCount - 1 do
    if FRec.GetTake(i).Id = FRecSelectedTakeId then
      Exit(i);
end;

{ ================= Mixer tab ================= }

function TfrmMain.SelectedMixStripId: Integer;
begin
  Result := 0;
  if (cboMixStrip.ItemIndex >= 0) then
    Result := Integer(NativeInt(cboMixStrip.Items.Objects[cboMixStrip.ItemIndex]));
end;

{ TfrmMixInsertParams only understands an insert's own Kind/Params text (see
  its header comment) - it knows nothing about TMixInsert.SidechainStripId,
  a separate model field the engine reads to key a dynamics insert off
  another strip's post-fader signal (UDAW.Mixer.Engine.ProcessStrip step 5).
  Rather than add a whole new designer control + strip-picker to that shared
  dialog for one field, a strip id typed as an ordinary "sidechain=<id>" row
  is recognised as a pseudo-param here, pulled back out of AParams before it
  is ever stored as a real DSP node param, and applied separately via
  TSetMixInsertSidechainCommand. Returns -1 (not 0) when no such row was
  present, so callers can tell "leave it alone" apart from "explicitly
  cleared to none" (sidechain=0). }
function TfrmMain.ExtractSidechainParam(var AParams: string): Integer;
var
  parts: TArray<string>;
  p: string;
  kept: string;
  val: Integer;
begin
  Result := -1;
  kept := '';
  parts := AParams.Split([';']);
  for p in parts do
  begin
    if p = '' then Continue;
    if StartsText('sidechain=', p) then
    begin
      if not TryStrToInt(Copy(p, Length('sidechain=') + 1, MaxInt), val) then val := 0;
      Result := val;
      Continue;
    end;
    if kept <> '' then kept := kept + ';';
    kept := kept + p;
  end;
  AParams := kept;
end;

procedure TfrmMain.RefreshMixAutomationParams(AStrip: TMixStrip);
var
  i, j, n, keepTarget, keepSub: Integer;
  keepParam: TAutomationParam;
  snd: TMixSend;
  ins: TMixInsert;

  function InsertInt(const AText, AKey: string; ADefault: Integer): Integer;
  var
    parts: TArray<string>;
    p: string;
    eq: Integer;
  begin
    Result := ADefault;
    parts := AText.Split([';']);
    for p in parts do
    begin
      eq := Pos('=', p);
      if (eq > 0) and SameText(Copy(p, 1, eq - 1), AKey) then
      begin
        if not TryStrToInt(Copy(p, eq + 1, MaxInt), Result) then Result := ADefault;
        Exit;
      end;
    end;
  end;

  procedure AddParam(const ACaption: string; AParam: TAutomationParam;
    ATarget, ASub: Integer);
  var
    k: Integer;
  begin
    k := Length(FMixAutoParams);
    SetLength(FMixAutoParams, k + 1);
    SetLength(FMixAutoTargets, k + 1);
    SetLength(FMixAutoSubs, k + 1);
    FMixAutoParams[k] := AParam;
    FMixAutoTargets[k] := ATarget;
    FMixAutoSubs[k] := ASub;
    cboMixAutoParam.Items.Add(ACaption);
  end;

begin
  keepParam := FMixAutoParam;
  keepTarget := FMixAutoTarget;
  keepSub := FMixAutoSub;
  cboMixAutoParam.Items.BeginUpdate;
  try
    cboMixAutoParam.Items.Clear;
    SetLength(FMixAutoParams, 0);
    SetLength(FMixAutoTargets, 0);
    SetLength(FMixAutoSubs, 0);
    AddParam('Fader', apFader, 0, 0);
    AddParam('Pan', apPan, 0, 0);
    AddParam('Mute', apMute, 0, 0);
    if AStrip <> nil then
    begin
      for i := 0 to AStrip.SendCount - 1 do
      begin
        snd := AStrip.GetSend(i);
        AddParam(Format('Send to strip %d', [snd.TargetStripId]), apSendGain,
          snd.TargetStripId, 0);
      end;
      for i := 0 to AStrip.InsertCount - 1 do
      begin
        ins := AStrip.GetInsert(i);
        if not SameText(ins.Kind, 'vst2') then Continue;
        n := InsertInt(ins.Params, 'paramcount', 0);
        if n < 0 then n := 0 else if n > 16384 then n := 16384;
        for j := 0 to n - 1 do
          AddParam(Format('VST %d parameter %d', [i + 1, j]), apInsertParam, i, j);
      end;
    end;
  finally
    cboMixAutoParam.Items.EndUpdate;
  end;
  cboMixAutoParam.ItemIndex := 0;
  for i := 0 to High(FMixAutoParams) do
    if (FMixAutoParams[i] = keepParam) and
       (FMixAutoTargets[i] = keepTarget) and (FMixAutoSubs[i] = keepSub) then
    begin
      cboMixAutoParam.ItemIndex := i;
      Break;
    end;
  cboMixAutoParamChange(cboMixAutoParam);
end;

{ Keeps the Mixer in sync with the Timeline: the Mixer must always have one
  skAudioTrack strip per Timeline audio channel (plus its always-present
  Master strip), so a channel newly added on the Timeline - or one loaded
  from an older project that predates this guarantee - never lands on a
  fader that does nothing. Creates and links (TSetMixStripInputCommand) a
  strip for every audio channel that isn't already claimed by one; a no-op
  once every channel has its strip. }
procedure TfrmMain.EnsureMixerStripsForTimelineTracks;
var
  i, j: Integer;
  trk: TTimelineTrack;
  claimed: Boolean;
  cmd: TAddMixStripCommand;
begin
  if (FProject = nil) or (FCmds = nil) then Exit;
  for i := 0 to FProject.Timeline.TrackCount - 1 do
  begin
    trk := FProject.Timeline.GetTrack(i);
    if trk.Kind <> tkAudio then Continue;
    claimed := False;
    for j := 0 to FProject.Mixer.StripCount - 1 do
      if FProject.Mixer.GetStrip(j).InputSourceId = trk.Id then
      begin
        claimed := True;
        Break;
      end;
    if claimed then Continue;
    try
      cmd := TAddMixStripCommand.Create(FProject, skAudioTrack, trk.Name);
      FCmds.Perform(cmd);
      FCmds.Perform(TSetMixStripInputCommand.Create(FProject, cmd.CreatedId, trk.Id));
    except
      on E: EUDAWError do ;  // strip may still exist even if the link failed
    end;
  end;
end;

procedure TfrmMain.RefreshMixerTab;
var
  m: TMixerModel;
  i, keepId: Integer;
  s: TMixStrip;
  sb: TStringBuilder;
begin
  if (FProject = nil) or FMixRefreshing then Exit;
  EnsureMixerStripsForTimelineTracks;
  FMixRefreshing := True;
  try
    m := FProject.Mixer;
    keepId := SelectedMixStripId;

    cboMixStrip.Items.BeginUpdate;
    try
      cboMixStrip.Items.Clear;
      for i := 0 to m.StripCount - 1 do
      begin
        s := m.GetStrip(i);
        cboMixStrip.Items.AddObject(
          Format('%s  [%s]', [s.Name, MixStripKindDisplay(s.Kind)]),
          TObject(NativeInt(s.Id)));
      end;
    finally
      cboMixStrip.Items.EndUpdate;
    end;
    cboMixStrip.ItemIndex := cboMixStrip.Items.Count - 1;
    for i := 0 to cboMixStrip.Items.Count - 1 do
      if Integer(NativeInt(cboMixStrip.Items.Objects[i])) = keepId then
        cboMixStrip.ItemIndex := i;

    cboMixRoute.Items.BeginUpdate;
    try
      cboMixRoute.Items.Clear;
      cboMixRoute.Items.AddObject('-> Master (default)', TObject(NativeInt(0)));
      for i := 0 to m.StripCount - 1 do
      begin
        s := m.GetStrip(i);
        if s.AcceptsBusInput and (s.Id <> SelectedMixStripId) then
          cboMixRoute.Items.AddObject('-> ' + s.Name, TObject(NativeInt(s.Id)));
      end;
    finally
      cboMixRoute.Items.EndUpdate;
    end;

    s := m.StripById(SelectedMixStripId);
    RefreshMixAutomationParams(s);
    if s <> nil then
    begin
      edtMixFader.Text := FormatFloat('0.###', s.FaderDb);
      edtMixPan.Text := FormatFloat('0.###', s.Pan);
      chkMixMute.Checked := s.Muted;
      chkMixSolo.Checked := s.Soloed;
      cboMixRoute.ItemIndex := 0;
      for i := 0 to cboMixRoute.Items.Count - 1 do
        if Integer(NativeInt(cboMixRoute.Items.Objects[i])) = s.OutputTargetId then
          cboMixRoute.ItemIndex := i;
      mnuMixRemove.Enabled := s.Kind <> skMaster;
      pmMixRemove.Enabled := s.Kind <> skMaster;
      cboMixAutoMode.ItemIndex := Ord(s.AutomationMode);
    end
    else
    begin
      mnuMixRemove.Enabled := False;
      pmMixRemove.Enabled := False;
    end;

    { "Link track": only meaningful for an skAudioTrack strip - that's the only
      kind TTimelinePlayer.AttachMixer will ever route a Timeline track through
      (see UDAW.Timeline.Playback.RefreshLinkedTracks). Without this control
      there was no way to set TMixStrip.InputSourceId at all, so a strip's
      fader/pan/inserts/sends/VST plugins never actually reached the Timeline's
      output - the Mixer tab was a dead end no matter how the engine wired it
      up underneath. }
    cboMixTrackLink.Items.BeginUpdate;
    try
      cboMixTrackLink.Items.Clear;
      cboMixTrackLink.Items.AddObject('(none)', TObject(NativeInt(0)));
      if (FProject <> nil) and (s <> nil) and (s.Kind = skAudioTrack) then
        for i := 0 to FProject.Timeline.TrackCount - 1 do
          with FProject.Timeline.GetTrack(i) do
            cboMixTrackLink.Items.AddObject(Name, TObject(NativeInt(Id)));
    finally
      cboMixTrackLink.Items.EndUpdate;
    end;
    cboMixTrackLink.Enabled := (s <> nil) and (s.Kind = skAudioTrack);
    cboMixTrackLink.ItemIndex := 0;
    if s <> nil then
      for i := 0 to cboMixTrackLink.Items.Count - 1 do
        if Integer(NativeInt(cboMixTrackLink.Items.Objects[i])) = s.InputSourceId then
          cboMixTrackLink.ItemIndex := i;

    s := m.MasterStrip;
    if s <> nil then
      lblMixMasterLoudness.Caption := Format(
        'Master:  %.1f / %.1f dBFS   M %.1f LUFS   I %.1f LUFS',
        [s.MeterPeakDbL, s.MeterPeakDbR, s.MeterLufs, s.MeterLufsIntegrated]);
    edtMixMeterHold.Text := FormatFloat('0', m.MeterHoldMs);
    edtMixMeterDecay.Text := FormatFloat('0.##', m.MeterHoldDecayDbPerSec);

    mnuMixUndo.Enabled := FCmds.CanUndo;
    pmMixUndo.Enabled := FCmds.CanUndo;
    mnuMixRedo.Enabled := FCmds.CanRedo;
    pmMixRedo.Enabled := FCmds.CanRedo;

    sb := TStringBuilder.Create;
    try
      sb.AppendLine(FProject.Mixer.Describe);
      sb.AppendLine('');
      sb.AppendLine('--- preview ---');
      sb.AppendLine(FMixPreview);
      memMix.Lines.Text := sb.ToString;
    finally
      sb.Free;
    end;
  finally
    FMixRefreshing := False;
  end;
  pbMixer.Invalidate;
  pbMixAuto.Invalidate;
end;

procedure TfrmMain.cboMixStripChange(Sender: TObject);
begin
  RefreshMixerTab;
end;

procedure TfrmMain.cboMixTrackLinkChange(Sender: TObject);
var
  trackId: Integer;
begin
  if FMixRefreshing or (cboMixTrackLink.ItemIndex < 0) or (SelectedMixStripId = 0) then Exit;
  trackId := Integer(NativeInt(cboMixTrackLink.Items.Objects[cboMixTrackLink.ItemIndex]));
  try
    FCmds.Perform(TSetMixStripInputCommand.Create(FProject, SelectedMixStripId, trackId));
  except
    on E: EUDAWError do
      MessageDlg(E.Message, mtWarning, [mbOK], 0);
  end;
  RefreshMixerTab;
end;

procedure TfrmMain.btnMixAddTrackClick(Sender: TObject);
var
  cmd: TAddMixStripCommand;
  trk: TTimelineTrack;
  i: Integer;
  trackClaimed: Boolean;
begin
  { If a Timeline track is selected and no strip already links to it, name
    the new strip after it and link it immediately - the common case is
    "give this Timeline track a channel strip", and making that the one-click
    default avoids every new user hitting the same "why doesn't the fader do
    anything" dead end that motivated adding cboMixTrackLink at all. }
  trk := nil;
  if FTlSelectedTrackId > 0 then
  begin
    trk := FProject.Timeline.TrackById(FTlSelectedTrackId);
    trackClaimed := False;
    for i := 0 to FProject.Mixer.StripCount - 1 do
      if FProject.Mixer.GetStrip(i).InputSourceId = FTlSelectedTrackId then
      begin
        trackClaimed := True;
        Break;
      end;
    if trackClaimed then trk := nil;
  end;

  if trk <> nil then
  begin
    cmd := TAddMixStripCommand.Create(FProject, skAudioTrack, trk.Name);
    FCmds.Perform(cmd);
    try
      FCmds.Perform(TSetMixStripInputCommand.Create(FProject, cmd.CreatedId, trk.Id));
    except
      on E: EUDAWError do ;   // strip still got created even if the link failed
    end;
  end
  else
    FCmds.Perform(TAddMixStripCommand.Create(FProject, skAudioTrack,
      Format('Audio %d', [FProject.Mixer.StripCount])));
  RefreshMixerTab;
end;

procedure TfrmMain.btnMixAddBusClick(Sender: TObject);
begin
  FCmds.Perform(TAddMixStripCommand.Create(FProject, skBus,
    Format('Bus %d', [FProject.Mixer.StripCount])));
  RefreshMixerTab;
end;

procedure TfrmMain.btnMixAddAuxClick(Sender: TObject);
begin
  FCmds.Perform(TAddMixStripCommand.Create(FProject, skAux,
    Format('Aux %d', [FProject.Mixer.StripCount])));
  RefreshMixerTab;
end;

procedure TfrmMain.btnMixAddVCAClick(Sender: TObject);
begin
  FCmds.Perform(TAddMixStripCommand.Create(FProject, skVCA,
    Format('VCA %d', [FProject.Mixer.StripCount])));
  RefreshMixerTab;
end;

{ Removing a strip mutates the live TMixerModel in place (TMixerStructuralCommand
  only round-trips through a text snapshot when Mutate fails) while the RT
  audio callback thread is concurrently walking that same model's strips/
  inserts to sum a playing Timeline/Tracker/Graph/Wav source - a strip
  disappearing (or its TMixStrip/insert objects being freed) out from under
  that walk is a use-after-free, which is what was crashing the whole app.
  Making the summing processor's model access safe under concurrent
  structural edits is real-time-audio work that needs to be done carefully
  and tested, not patched blind, so for now this refuses the edit and tells
  the user to stop playback first rather than risk the crash. }
procedure TfrmMain.btnMixRemoveClick(Sender: TObject);
begin
  if SelectedMixStripId = 0 then Exit;
  if (App <> nil) and (App.Audio <> nil) and
    (FGraphPlaying or FWavPlaying or FTrkPlaying or FTlPlaying) then
  begin
    MessageDlg('Playback is active. Stop playback before removing a mixer strip.',
      mtWarning, [mbOK], 0);
    Exit;
  end;
  try
    FCmds.Perform(TRemoveMixStripCommand.Create(FProject, SelectedMixStripId));
  except
    on E: EUDAWError do
      MessageDlg(E.Message, mtWarning, [mbOK], 0);
  end;
  RefreshMixerTab;
end;

{ Mute/Solo previously only took effect when "Apply strip" was clicked - the
  checkboxes themselves had no OnClick handler at all, so toggling one looked
  like it did nothing until you remembered to hit Apply. Every other strip
  control that has a live equivalent (fader/pan drag) already applies
  instantly; these should too. }
procedure TfrmMain.chkMixMuteClick(Sender: TObject);
var
  id: Integer;
begin
  id := SelectedMixStripId;
  if id = 0 then Exit;
  FCmds.Perform(TSetMixStripFlagCommand.Create(FProject, id, mfgMute, chkMixMute.Checked));
  pbMixer.Invalidate;
end;

procedure TfrmMain.chkMixSoloClick(Sender: TObject);
var
  id: Integer;
begin
  id := SelectedMixStripId;
  if id = 0 then Exit;
  FCmds.Perform(TSetMixStripFlagCommand.Create(FProject, id, mfgSolo, chkMixSolo.Checked));
  pbMixer.Invalidate;
end;

procedure TfrmMain.btnMixApplyClick(Sender: TObject);
var
  id: Integer;
  fader, pan: Double;
  fs: TFormatSettings;
  routeId: Integer;
  s: TMixStrip;
begin
  id := SelectedMixStripId;
  if id = 0 then Exit;
  fs := TFormatSettings.Invariant;
  if not TryStrToFloat(StringReplace(edtMixFader.Text, ',', '.', [rfReplaceAll]), fader, fs) then
    fader := 0;
  if not TryStrToFloat(StringReplace(edtMixPan.Text, ',', '.', [rfReplaceAll]), pan, fs) then
    pan := 0;
  try
    FCmds.Perform(TSetMixStripFloatCommand.Create(FProject, id, mffFader, fader));
    FCmds.Perform(TSetMixStripFloatCommand.Create(FProject, id, mffPan, pan));
    FCmds.Perform(TSetMixStripFlagCommand.Create(FProject, id, mfgMute, chkMixMute.Checked));
    FCmds.Perform(TSetMixStripFlagCommand.Create(FProject, id, mfgSolo, chkMixSolo.Checked));
    s := FProject.Mixer.StripById(id);
    if FTlPlaying and (s <> nil) and
       (s.AutomationMode in [amTouch, amLatch, amWrite]) then
    begin
      FCmds.Perform(TAddAutomationPointCommand.Create(FProject, id, apFader,
        FProject.Timeline.PlayheadSeconds, fader));
      FCmds.Perform(TAddAutomationPointCommand.Create(FProject, id, apPan,
        FProject.Timeline.PlayheadSeconds, pan));
      FCmds.Perform(TAddAutomationPointCommand.Create(FProject, id, apMute,
        FProject.Timeline.PlayheadSeconds, Ord(chkMixMute.Checked)));
    end;
    if cboMixRoute.ItemIndex >= 0 then
    begin
      routeId := Integer(NativeInt(cboMixRoute.Items.Objects[cboMixRoute.ItemIndex]));
      FCmds.Perform(TSetMixStripRouteCommand.Create(FProject, id, routeId));
    end;
  except
    on E: EUDAWError do
      MessageDlg(E.Message, mtWarning, [mbOK], 0);
  end;
  RefreshMixerTab;
end;

procedure TfrmMain.btnMixAddEQClick(Sender: TObject);
var
  kind, params, editedParams: string;
  sc: Integer;
  s: TMixStrip;
begin
  if SelectedMixStripId = 0 then Exit;
  case cboMixInsertKind.ItemIndex of
    0: begin kind := 'gain';       params := 'db=6'; end;
    1: begin kind := 'parametriceq'; params := ''; end;   // TParametricEQNode fills in its own 6-band defaults
    2: begin kind := 'graphiceq';  params := 'bands=10;gains=0,0,0,0,0,0,0,0,0,0'; end;
    3: begin kind := 'compressor'; params := 'type=compressor;thresh=-18;ratio=3;knee=6;attack=10;release=120;makeup=0'; end;
    4: begin kind := 'lookaheadlimiter'; params := 'ceiling=-0.3;release=100;lookahead=5'; end;
    5: begin kind := 'compressor'; params := 'type=gate;thresh=-40;ratio=6;knee=2;attack=1;release=60;makeup=0;hold=15;range=-60'; end;
    6: begin kind := 'compressor'; params := 'type=expander;thresh=-30;ratio=2;knee=6;attack=5;release=100;makeup=0'; end;
    7: begin kind := 'compressor'; params := 'type=deesser;thresh=-24;ratio=4;knee=3;attack=1;release=80;makeup=0'; end;
    8: begin kind := 'modulation'; params := 'type=chorus;rate=0.6;depth=0.6;mix=0.4;stereo=90'; end;
    9: begin kind := 'modulation'; params := 'type=flanger;rate=0.25;depth=0.7;mix=0.5;fb=0.4;stereo=90'; end;
    10: begin kind := 'modulation'; params := 'type=phaser;rate=0.4;depth=0.8;mix=0.5;fb=0.3;stages=6;stereo=90'; end;
    11: begin kind := 'modulation'; params := 'type=tremolo;rate=4;depth=0.6;mix=1'; end;
    12: begin kind := 'modulation'; params := 'type=autopan;rate=0.5;depth=1;mix=1'; end;
    13: begin kind := 'distortion'; params := 'type=saturation;drive=3;trim=0;mix=1'; end;
    14: begin kind := 'distortion'; params := 'type=hardclip;drive=3;trim=0;mix=1'; end;
    15: begin kind := 'distortion'; params := 'type=foldback;drive=3;trim=0;mix=1'; end;
    16: begin kind := 'distortion'; params := 'type=bitcrush;bits=8;down=4;mix=1'; end;
    17: begin kind := 'reverb';     params := 'size=0.7;damp=0.4;width=1;mix=0.3;predelay=15'; end;
    18: begin kind := 'delay';      params := 'ms=250;fb=0.3;mix=0.3;pingpong=0'; end;
    19: begin kind := 'delay';     params := 'ms=250;fb=0.35;mix=0.35;pingpong=1'; end;
    20: begin kind := 'stereowidth'; params := 'width=1.4'; end;
    21: begin kind := 'transientshaper'; params := 'attack=6;sustain=0'; end;
    22: begin kind := 'exciter';   params := 'freq=3000;drive=4;mix=0.25'; end;
    23: begin kind := 'pitchshift'; params := 'semitones=0'; end;
    24: begin kind := 'multibandcomp'; params := ''; end;   // TMultibandCompNode fills in its own 3-band defaults
    25: begin kind := 'mastering'; params := ''; end;       // TMasteringNode fills in its own defaults
  else
    kind := 'gain'; params := 'db=0';
  end;
  { let the user tune the new insert's initial params before it is ever
    committed to the mixer model, instead of add-then-edit-separately - the
    same dialog pbMixerDblClick reuses for editing an EXISTING insert
    (step 2/3 of the mixer effects pass share one editor). A blank params
    string (e.g. 'parametriceq') means the node fills in its own defaults on
    first Execute - present that with no rows rather than none at all. }
  editedParams := params;
  if not TfrmMixInsertParams.Edit(Self, kind, cboMixInsertKind.Text, params, editedParams) then
    Exit;
  sc := ExtractSidechainParam(editedParams);
  FCmds.Perform(TAddMixInsertCommand.Create(FProject, SelectedMixStripId, kind, editedParams,
    -1, cboMixInsertKind.Text));
  if sc >= 0 then
  begin
    s := FProject.Mixer.StripById(SelectedMixStripId);
    if (s <> nil) and (s.InsertCount > 0) then
      FCmds.Perform(TSetMixInsertSidechainCommand.Create(FProject, SelectedMixStripId,
        s.InsertCount - 1, sc));
  end;
  RefreshMixerTab;
end;

procedure TfrmMain.btnMixDelInsertClick(Sender: TObject);
var
  s: TMixStrip;
begin
  s := FProject.Mixer.StripById(SelectedMixStripId);
  if (s = nil) or (s.InsertCount = 0) then Exit;
  FCmds.Perform(TRemoveMixInsertCommand.Create(FProject, s.Id, s.InsertCount - 1));
  RefreshMixerTab;
end;

procedure TfrmMain.btnMixUndoClick(Sender: TObject);
begin
  FCmds.Undo;
  RefreshMixerTab;
end;

procedure TfrmMain.btnMixRedoClick(Sender: TObject);
begin
  FCmds.Redo;
  RefreshMixerTab;
end;

type
  TMixToneProvider = class(TInterfacedObject, IMixInputProvider)
  private
    FRate: Integer;
    FPhase: Double;
  public
    constructor Create(ASampleRate: Integer);
    procedure RenderStripInput(AStripId: Integer; ABuffer: TAudioBuffer);
  end;

constructor TMixToneProvider.Create(ASampleRate: Integer);
begin
  inherited Create;
  FRate := ASampleRate;
end;

procedure TMixToneProvider.RenderStripInput(AStripId: Integer; ABuffer: TAudioBuffer);
var
  i, ch, n: Integer;
  freq: Double;
  tmp: array of Single;
  p: PAudioSample;
begin
  { a distinct low-level tone per strip so the preview mix is audibly a sum }
  n := ABuffer.FrameCount;
  if n <= 0 then Exit;
  freq := 110.0 * AStripId;
  SetLength(tmp, n);
  for i := 0 to n - 1 do
  begin
    tmp[i] := Single(0.2 * Sin(FPhase));
    FPhase := FPhase + 2 * Pi * freq / FRate;
    if FPhase > 2 * Pi then FPhase := FPhase - 2 * Pi;
  end;
  for ch := 0 to ABuffer.ChannelCount - 1 do
  begin
    p := ABuffer.ChannelPtr(ch);
    for i := 0 to n - 1 do
    begin
      p^ := tmp[i];
      Inc(p);
    end;
  end;
end;

procedure TfrmMain.btnMixPreviewClick(Sender: TObject);
var
  proc: TMixerProcessor;
  prov: IMixInputProvider;
  planar: TAudioPlanar;
  master: TMixStrip;
  frames, ch, i: Integer;
  pk, rms: Double;
begin
  proc := TMixerProcessor.Create(FProject.Mixer);
  try
    prov := TMixToneProvider.Create(FProject.SampleRate);
    proc.SetInputProvider(prov);
    proc.SetAutomation(FProject.Mixer.Automation);
    proc.SetModulation(FProject.Mixer.Modulation);
    proc.SetPlayheadSeconds(FProject.Timeline.PlayheadSeconds);
    try
      proc.Prepare(FProject.SampleRate, 480, FProject.Channels);
    except
      on E: EUDAWError do
      begin
        FMixPreview := 'cannot render: ' + E.Message;
        RefreshMixerTab;
        Exit;
      end;
    end;
    frames := FProject.SampleRate div 2;   // 0.5 s
    planar := proc.RenderToPlanar(frames);
    pk := 0;
    rms := 0;
    for ch := 0 to High(planar) do
      for i := 0 to High(planar[ch]) do
      begin
        if Abs(planar[ch][i]) > pk then pk := Abs(planar[ch][i]);
        rms := rms + Sqr(planar[ch][i]);
      end;
    if (Length(planar) > 0) and (frames > 0) then
      rms := Sqrt(rms / (Length(planar) * frames));
    master := FProject.Mixer.MasterStrip;
    FMixPreview := Format(
      'rendered %d strip(s), %d frames @ %d Hz'#13#10 +
      '  master out : peak %.4f (%.1f dBFS)   rms %.4f (%.1f dBFS)'#13#10 +
      '  master meter: peak L %.1f  peak R %.1f  rms %.1f  LUFS-M %.1f',
      [proc.StripRTCount, frames, FProject.SampleRate,
       pk, LinearToDb(pk), rms, LinearToDb(rms),
       master.MeterPeakDbL, master.MeterPeakDbR, master.MeterRmsDb, master.MeterLufs]);
  finally
    proc.Free;
  end;
  RefreshMixerTab;
end;

{ Colour badge per strip kind - a quick visual "what is this" cue distinct
  from the name text, since Track / Bus / Aux / VCA / Master strips behave
  quite differently (routing targets, whether they carry audio at all). }
function MixKindBadgeColor(AKind: TMixStripKind): TColor;
begin
  case AKind of
    skMaster: Result := $00A0703C;   // blue-ish accent (BGR: warm gold)
    skVCA:    Result := $00A050A0;   // violet
    skBus:    Result := $00A0A050;   // teal
    skAux:    Result := $0050A0A0;   // olive
    skInput:  Result := $00707070;   // grey
  else
    Result := $00707030;            // audio track: steel blue
  end;
end;

function MixKindBadgeLetter(AKind: TMixStripKind): string;
begin
  case AKind of
    skMaster: Result := 'MST';
    skVCA:    Result := 'VCA';
    skBus:    Result := 'BUS';
    skAux:    Result := 'AUX';
    skInput:  Result := 'IN';
  else
    Result := 'TRK';
  end;
end;

{ Renders one professional-looking channel strip - kind badge, name, M/S
  indicators, a labelled dB scale next to a groove-and-cap fader, a two-tone
  peak meter with a distinct clip zone, a pan notch and an insert/send dot
  row - into ABuf at AX..AX+AWidth, ARect returning the strip's full on-screen
  hit box for click-to-select. }
function MixColor(A, B: TColor; T: Double): TColor; forward;
function MixInsertKindDisplay(const AKind, AParams: string): string; forward;

procedure TfrmMain.DrawMixStrip(ABuf: TCanvas; AX, AWidth, AHeight: Integer;
  const AStrip: TMixStrip; ASelected: Boolean; out ARect: TRect);
const
  HEADER_H = 34;
  FOOTER_H = 100;   { room for the dot row + up to 4 effect-name lines; keep equal to pbMixerMouseDown/MouseMove }
var
  theme: TUDAWTheme;
  bodyTop, bodyBottom, meterTop, meterBottom, faderTop, faderBottom: Integer;
  faderY, meterH, meterHR, panX, i, dotX, dotY: Integer;
  frac: Double;
  meterCol: TColor;
  txt: string;
begin
  theme := CurrentTheme;
  ARect := Rect(AX, 2, AX + AWidth - 4, AHeight - 2);

  { strip frame, tinted by kind, brighter border when selected }
  ABuf.Brush.Style := bsSolid;
  if AStrip.Kind = skMaster then ABuf.Brush.Color := $00302820
  else if AStrip.Kind = skVCA then ABuf.Brush.Color := $00302030
  else if AStrip.Kind in [skBus, skAux] then ABuf.Brush.Color := $00203028
  else ABuf.Brush.Color := theme.PanelBackground;
  if ASelected then
  begin
    ABuf.Brush.Color := MixColor(ABuf.Brush.Color, theme.Selection, 0.35);
    ABuf.Pen.Color := theme.Selection;
  end
  else ABuf.Pen.Color := theme.Border;
  ABuf.Pen.Width := IfThen(ASelected, 2, 1);
  ABuf.Rectangle(ARect);
  ABuf.Pen.Width := 1;

  { header: kind badge + name, muted name dims }
  ABuf.Brush.Style := bsSolid;
  ABuf.Brush.Color := MixKindBadgeColor(AStrip.Kind);
  ABuf.FillRect(Rect(ARect.Left + 1, ARect.Top + 1, ARect.Right - 1, ARect.Top + 15));
  ABuf.Brush.Style := bsClear;
  ABuf.Font.Color := clWhite;
  ABuf.Font.Style := [fsBold];
  ABuf.TextOut(ARect.Left + 4, ARect.Top + 1, MixKindBadgeLetter(AStrip.Kind));
  ABuf.Font.Style := [];

  if AStrip.Muted then ABuf.Font.Color := theme.MeterClip
  else ABuf.Font.Color := theme.Text;
  txt := AStrip.Name;
  while (ABuf.TextWidth(txt) > AWidth - 10) and (Length(txt) > 1) do
    Delete(txt, Length(txt), 1);
  ABuf.TextOut(ARect.Left + 4, ARect.Top + 17, txt);

  { M / S indicator chips, lit when active }
  if AStrip.Muted then ABuf.Brush.Color := theme.MeterClip else ABuf.Brush.Color := theme.Border;
  ABuf.Brush.Style := bsSolid;
  ABuf.FillRect(Rect(ARect.Right - 40, ARect.Top + 17, ARect.Right - 22, ARect.Top + 31));
  ABuf.Brush.Style := bsClear;
  ABuf.Font.Color := IfThen(AStrip.Muted, clWhite, theme.SecondaryText);
  ABuf.TextOut(ARect.Right - 37, ARect.Top + 17, 'M');

  if AStrip.Soloed then ABuf.Brush.Color := $0020D0F0 { amber-ish (BGR) } else ABuf.Brush.Color := theme.Border;
  ABuf.Brush.Style := bsSolid;
  ABuf.FillRect(Rect(ARect.Right - 20, ARect.Top + 17, ARect.Right - 2, ARect.Top + 31));
  ABuf.Brush.Style := bsClear;
  ABuf.Font.Color := IfThen(AStrip.Soloed, clWhite, theme.SecondaryText);
  ABuf.TextOut(ARect.Right - 17, ARect.Top + 17, 'S');

  { pan notch: a small groove with a tick at the current pan (-1..+1) }
  panX := ARect.Left + 4 +
    Round((AStrip.Pan + 1.0) / 2.0 * (AWidth - 14));
  ABuf.Pen.Color := theme.Grid;
  ABuf.MoveTo(ARect.Left + 4, ARect.Top + HEADER_H);
  ABuf.LineTo(ARect.Right - 6, ARect.Top + HEADER_H);
  ABuf.Pen.Color := theme.Accent;
  ABuf.MoveTo(panX, ARect.Top + HEADER_H - 3);
  ABuf.LineTo(panX, ARect.Top + HEADER_H + 3);

  { the fader/meter body, between the header and the footer dot row }
  bodyTop := ARect.Top + HEADER_H + 6;
  bodyBottom := ARect.Bottom - FOOTER_H;
  if bodyBottom < bodyTop + 10 then bodyBottom := bodyTop + 10;
  faderTop := bodyTop;
  faderBottom := bodyBottom;
  meterTop := bodyTop;
  meterBottom := bodyBottom;

  { fader groove }
  ABuf.Pen.Color := theme.Grid;
  ABuf.MoveTo((ARect.Left + ARect.Right) div 2 - 8, faderTop);
  ABuf.LineTo((ARect.Left + ARect.Right) div 2 - 8, faderBottom);

  { fader cap: -60..+12 dB mapped over the groove, drawn as a small filled
    rectangle ("cap") rather than a bare line so it reads as a real control }
  frac := (AStrip.FaderDb + 60.0) / 72.0;
  if frac < 0 then frac := 0 else if frac > 1 then frac := 1;
  faderY := Round((faderBottom - faderTop) * (1.0 - frac)) + faderTop;
  ABuf.Brush.Style := bsSolid;
  ABuf.Brush.Color := theme.Accent;
  ABuf.Pen.Color := theme.Text;
  ABuf.Rectangle(Rect((ARect.Left + ARect.Right) div 2 - 14, faderY - 3,
    (ARect.Left + ARect.Right) div 2 - 2, faderY + 3));

  ABuf.Brush.Style := bsClear;
  ABuf.Font.Color := theme.SecondaryText;
  ABuf.TextOut(ARect.Left + 4, faderBottom + 2,
    FormatFloat('0.0', AStrip.FaderDb) + ' dB');
  ABuf.TextOut(ARect.Left + 4, faderBottom + 16,
    Format('R %.0f  I %.0f', [AStrip.MeterRmsDb, AStrip.MeterLufsIntegrated]));

  { stereo peak meter (L/R), green -> yellow -> red zones, distinct clip cap }
  frac := (AStrip.MeterPeakDbL + 60.0) / 60.0;
  if frac < 0 then frac := 0 else if frac > 1 then frac := 1;
  meterH := Round((meterBottom - meterTop) * frac);
  frac := (AStrip.MeterPeakDbR + 60.0) / 60.0;
  if frac < 0 then frac := 0 else if frac > 1 then frac := 1;
  meterHR := Round((meterBottom - meterTop) * frac);

  if AStrip.MeterPeakDbL >= 0.0 then meterCol := theme.MeterClip
  else if AStrip.MeterPeakDbL > -6.0 then meterCol := $0020D0F0
  else meterCol := theme.Meter;
  ABuf.Brush.Style := bsSolid;
  ABuf.Brush.Color := $00181818;
  ABuf.FillRect(Rect(ARect.Right - 16, meterTop, ARect.Right - 4, meterBottom));
  ABuf.Brush.Color := meterCol;
  ABuf.FillRect(Rect(ARect.Right - 16, meterBottom - meterH, ARect.Right - 11, meterBottom));

  if AStrip.MeterPeakDbR >= 0.0 then meterCol := theme.MeterClip
  else if AStrip.MeterPeakDbR > -6.0 then meterCol := $0020D0F0
  else meterCol := theme.Meter;
  ABuf.Brush.Color := meterCol;
  ABuf.FillRect(Rect(ARect.Right - 10, meterBottom - meterHR, ARect.Right - 5, meterBottom));

  { peak-hold caps: a 1px line at the held peak, decaying per
    UDAW.DSP.Meter.TPeakMeter.HoldDb (see TMixerEngine.ProcessStrip) }
  ABuf.Pen.Color := theme.Text;
  frac := (AStrip.MeterHoldDbL + 60.0) / 60.0;
  if frac < 0 then frac := 0 else if frac > 1 then frac := 1;
  i := meterBottom - Round((meterBottom - meterTop) * frac);
  ABuf.MoveTo(ARect.Right - 16, i); ABuf.LineTo(ARect.Right - 11, i);
  frac := (AStrip.MeterHoldDbR + 60.0) / 60.0;
  if frac < 0 then frac := 0 else if frac > 1 then frac := 1;
  i := meterBottom - Round((meterBottom - meterTop) * frac);
  ABuf.MoveTo(ARect.Right - 10, i); ABuf.LineTo(ARect.Right - 5, i);

  { latching clip LED - a small square in the badge bar (always has room,
    unlike the name/M/S row which is width-constrained) - click resets it
    (see pbMixerMouseDown) }
  SetLength(FMixClipRects, Length(FMixClipRects) + 1);
  SetLength(FMixClipIds, Length(FMixClipIds) + 1);
  FMixClipIds[High(FMixClipIds)] := AStrip.Id;
  FMixClipRects[High(FMixClipRects)] := Rect(ARect.Left + 22, ARect.Top + 3, ARect.Left + 30, ARect.Top + 11);
  ABuf.Brush.Style := bsSolid;
  if AStrip.ClipL or AStrip.ClipR then ABuf.Brush.Color := theme.MeterClip
  else ABuf.Brush.Color := clGray;
  ABuf.FillRect(FMixClipRects[High(FMixClipRects)]);

  { insert/send dot row: one small dot per insert (accent) and per send
    (secondary), so the chain's presence and length is visible without
    opening the strip - a fast "does this channel have anything on it". }
  dotY := ARect.Bottom - FOOTER_H + 34;
  dotX := ARect.Left + 4;
  ABuf.Brush.Style := bsSolid;
  for i := 0 to AStrip.InsertCount - 1 do
  begin
    if dotX > ARect.Right - 8 then Break;
    ABuf.Brush.Color := theme.Accent;
    ABuf.FillRect(Rect(dotX, dotY, dotX + 5, dotY + 5));
    { drag-reorder + click hit-box (a bit larger than the painted dot so it's
      actually grabbable) - see pbMixerMouseDown/MouseMove/MouseUp }
    SetLength(FMixInsertDotRects, Length(FMixInsertDotRects) + 1);
    SetLength(FMixInsertDotStripId, Length(FMixInsertDotStripId) + 1);
    SetLength(FMixInsertDotIndex, Length(FMixInsertDotIndex) + 1);
    FMixInsertDotRects[High(FMixInsertDotRects)] := Rect(dotX - 1, dotY - 3, dotX + 6, dotY + 8);
    FMixInsertDotStripId[High(FMixInsertDotStripId)] := AStrip.Id;
    FMixInsertDotIndex[High(FMixInsertDotIndex)] := i;
    Inc(dotX, 7);
  end;
  Inc(dotX, 3);
  for i := 0 to AStrip.SendCount - 1 do
  begin
    if dotX > ARect.Right - 8 then Break;
    ABuf.Brush.Color := theme.SecondaryText;
    ABuf.FillRect(Rect(dotX, dotY, dotX + 5, dotY + 5));
    Inc(dotX, 7);
  end;

  { the effects themselves, by name, one line each under the dot row, so what
    is on the channel is readable without opening it (bypassed ones dimmed) }
  ABuf.Brush.Style := bsClear;
  dotY := dotY + 10;
  for i := 0 to AStrip.InsertCount - 1 do
  begin
    if dotY + 11 > ARect.Bottom - 2 then Break;
    if (i = 3) and (AStrip.InsertCount > 4) then
    begin
      ABuf.Font.Color := theme.SecondaryText;
      ABuf.TextOut(ARect.Left + 4, dotY, Format('+%d more', [AStrip.InsertCount - 3]));
      Break;
    end;
    if AStrip.GetInsert(i).Bypass then ABuf.Font.Color := theme.SecondaryText
    else ABuf.Font.Color := theme.Text;
    txt := Format('%d %s', [i + 1, MixInsertKindDisplay(AStrip.GetInsert(i).Kind,
      AStrip.GetInsert(i).Params)]);
    while (ABuf.TextWidth(txt) > AWidth - 10) and (Length(txt) > 1) do
      Delete(txt, Length(txt), 1);
    ABuf.TextOut(ARect.Left + 4, dotY, txt);
    Inc(dotY, 11);
  end;
end;

procedure TfrmMain.pbMixerPaint(Sender: TObject);
var
  cv: TCanvas;
  w, h, n, i, x, barW: Integer;
  m: TMixerModel;
  s: TMixStrip;
  r: TRect;
  theme: TUDAWTheme;
begin
  w := pbMixer.Width;
  h := pbMixer.Height;
  if (w <= 0) or (h <= 0) then Exit;

  { paint into an off-screen bitmap and blit it in one shot - pbMixer can be
    invalidated at near-frame rate while meters are live, and drawing this
    many strips' worth of rectangles/text straight to the on-screen DC
    flickered badly; this mirrors the Timeline's FTlBuffer fix. }
  FMixBuffer.SetSize(w, h);
  cv := FMixBuffer.Canvas;
  theme := CurrentTheme;
  cv.Brush.Style := bsSolid;
  cv.Brush.Color := theme.Background;
  cv.FillRect(Rect(0, 0, w, h));

  SetLength(FMixStripRects, 0);
  SetLength(FMixStripIds, 0);
  SetLength(FMixClipRects, 0);
  SetLength(FMixClipIds, 0);
  SetLength(FMixInsertDotRects, 0);
  SetLength(FMixInsertDotStripId, 0);
  SetLength(FMixInsertDotIndex, 0);
  if FProject = nil then
  begin
    pbMixer.Canvas.Draw(0, 0, FMixBuffer);
    Exit;
  end;
  m := FProject.Mixer;
  n := m.StripCount;
  if n = 0 then
  begin
    pbMixer.Canvas.Draw(0, 0, FMixBuffer);
    Exit;
  end;
  if FMixZoomFactor <= 0 then FMixZoomFactor := 1.0;
  barW := Round(((w - 8) div n) * FMixZoomFactor);
  if barW < 60 then barW := 60;

  SetLength(FMixStripRects, n);
  SetLength(FMixStripIds, n);
  for i := 0 to n - 1 do
  begin
    s := m.GetStrip(i);
    x := 4 + i * barW;
    FMixStripIds[i] := s.Id;
    if x > w - 40 then
    begin
      FMixStripRects[i] := Rect(0, 0, 0, 0);
      Continue;
    end;
    DrawMixStrip(cv, x, barW, h, s, s.Id = SelectedMixStripId, r);
    FMixStripRects[i] := r;
  end;

  pbMixer.Canvas.Draw(0, 0, FMixBuffer);
end;

function MixColor(A, B: TColor; T: Double): TColor;
var
  ca, cb: LongInt;
  ar, ag, ab, br, bg, bb: Byte;
begin
  ca := ColorToRGB(A);
  cb := ColorToRGB(B);
  ar := ca and $FF; ag := (ca shr 8) and $FF; ab := (ca shr 16) and $FF;
  br := cb and $FF; bg := (cb shr 8) and $FF; bb := (cb shr 16) and $FF;
  Result := TColor(Byte(Round(ar + (br - ar) * T)) or
    (Byte(Round(ag + (bg - ag) * T)) shl 8) or
    (Byte(Round(ab + (bb - ab) * T)) shl 16));
end;

function MixInsertKV(const AText, AKey: string): string;
var
  parts: TArray<string>;
  p: string;
  eq: Integer;
begin
  Result := '';
  parts := AText.Split([';']);
  for p in parts do
  begin
    eq := Pos('=', p);
    if eq <= 0 then Continue;
    if SameText(Copy(p, 1, eq - 1), AKey) then Exit(Copy(p, eq + 1, MaxInt));
  end;
end;

{ Friendly label for one insert's raw Kind id (+ its current Params, since a
  few kinds share one Kind string and are told apart only by a "type=" key -
  compressor/gate, and modulation/distortion's variant) - used by
  pbMixerDblClick to caption TfrmMixInsertParams; cboMixInsertKind.Text
  already gives btnMixAddEQClick a display name for the not-yet-added case. }
function MixInsertKindDisplay(const AKind, AParams: string): string;
var
  t: string;
begin
  t := LowerCase(MixInsertKV(AParams, 'type'));
  if SameText(AKind, 'gain') then Result := 'Trim gain'
  else if SameText(AKind, 'parametriceq') then Result := 'Parametric EQ (6-band)'
  else if SameText(AKind, 'graphiceq') then Result := 'Graphic EQ (10-band)'
  else if SameText(AKind, 'compressor') then
  begin
    if t = 'gate' then Result := 'Noise gate' else Result := 'Compressor';
  end
  else if SameText(AKind, 'lookaheadlimiter') then Result := 'Limiter (lookahead brickwall)'
  else if SameText(AKind, 'modulation') then
  begin
    if t <> '' then Result := 'Modulation (' + t + ')' else Result := 'Modulation';
  end
  else if SameText(AKind, 'distortion') then Result := 'Saturation'
  else if SameText(AKind, 'reverb') then Result := 'Reverb'
  else if SameText(AKind, 'delay') then
  begin
    if MixInsertKV(AParams, 'pingpong') = '1' then Result := 'Delay (ping-pong)'
    else Result := 'Delay';
  end
  else if SameText(AKind, 'stereowidth') then Result := 'Stereo Width'
  else if SameText(AKind, 'transientshaper') then Result := 'Transient Shaper'
  else if SameText(AKind, 'exciter') then Result := 'Exciter'
  else if SameText(AKind, 'pitchshift') then Result := 'Pitch Shift'
  else if SameText(AKind, 'vst2') then Result := 'VST Plugin'
  else if SameText(AKind, 'clap') then Result := 'CLAP Plugin'
  else if SameText(AKind, 'vst3') then Result := 'VST3 Plugin'
  else Result := AKind;
end;

procedure TfrmMain.pbMixerMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
const
  HEADER_H = 34;
  FOOTER_H = 100;   { must match DrawMixStrip }
var
  i, k, centerX, bodyTop, bodyBottom: Integer;
  s: TMixStrip;
  faderRect, panRect: TRect;
begin
  FMixDragMode := mdmNone;
  { pbMixer.PopupMenu (pmMixer) auto-shows on WM_CONTEXTMENU, dispatched
    AFTER this handler and pbMixerMouseUp both return - too late to cancel
    from either of them once a right-click has landed on an insert dot
    (see below). Un-nil-ing it here, every mouse-down, guarantees it is back
    to normal before the NEXT right-click's WM_CONTEXTMENU is dispatched. }
  pbMixer.PopupMenu := pmMixer;
  if Button = mbLeft then
  begin
    { latching clip LEDs: click resets, never starts a drag }
    for i := 0 to High(FMixClipRects) do
      if PtInRect(FMixClipRects[i], Point(X, Y)) then
      begin
        if FProject <> nil then
        begin
          s := FProject.Mixer.StripById(FMixClipIds[i]);
          if s <> nil then s.ResetClip;
        end;
        pbMixer.Invalidate;
        Exit;
      end;

    { insert dots: begin a drag-reorder (see pbMixerMouseUp) }
    for i := 0 to High(FMixInsertDotRects) do
      if PtInRect(FMixInsertDotRects[i], Point(X, Y)) then
      begin
        FMixDragMode := mdmReorderInsert;
        FMixDragStripId := FMixInsertDotStripId[i];
        FMixDragInsertIndex := FMixInsertDotIndex[i];
        Exit;
      end;
  end
  else if Button = mbRight then
  begin
    { right-click an insert dot: remove that single insert, instead of
      falling through to the generic strip context menu (pmMixer, which only
      knows about whole strips, not individual inserts) }
    for i := 0 to High(FMixInsertDotRects) do
      if PtInRect(FMixInsertDotRects[i], Point(X, Y)) then
      begin
        pbMixer.PopupMenu := nil;   { see the comment above: suppress pmMixer for THIS click }
        if (FProject <> nil) and
           (MessageDlg('Remove this insert?', mtConfirmation, [mbYes, mbNo], 0) = mrYes) then
        begin
          FCmds.Perform(TRemoveMixInsertCommand.Create(FProject,
            FMixInsertDotStripId[i], FMixInsertDotIndex[i]));
          RefreshMixerTab;
        end;
        Exit;
      end;
  end;

  for i := 0 to High(FMixStripRects) do
  begin
    if not PtInRect(FMixStripRects[i], Point(X, Y)) then Continue;

    for k := 0 to cboMixStrip.Items.Count - 1 do
      if Integer(NativeInt(cboMixStrip.Items.Objects[k])) = FMixStripIds[i] then
      begin
        cboMixStrip.ItemIndex := k;
        cboMixStripChange(cboMixStrip);
        Break;
      end;

    if (Button <> mbLeft) or (FProject = nil) then Exit;
    s := FProject.Mixer.StripById(FMixStripIds[i]);
    if s = nil then Exit;

    { the kind-badge bar at the very top of the strip: drag to reorder }
    if Y <= FMixStripRects[i].Top + 16 then
    begin
      FMixDragMode := mdmReorderStrip;
      FMixDragStripId := s.Id;
      Exit;
    end;

    { M/S chips: same rects DrawMixStrip paints them at (Top+17..+31), which
      looked clickable but previously did nothing - toggle on click, exactly
      like clicking a clip-LED resets it above. }
    if PtInRect(Rect(FMixStripRects[i].Right - 40, FMixStripRects[i].Top + 17,
      FMixStripRects[i].Right - 22, FMixStripRects[i].Top + 31), Point(X, Y)) then
    begin
      FCmds.Perform(TSetMixStripFlagCommand.Create(FProject, s.Id, mfgMute, not s.Muted));
      pbMixer.Invalidate;
      Exit;
    end;
    if PtInRect(Rect(FMixStripRects[i].Right - 20, FMixStripRects[i].Top + 17,
      FMixStripRects[i].Right - 2, FMixStripRects[i].Top + 31), Point(X, Y)) then
    begin
      FCmds.Perform(TSetMixStripFlagCommand.Create(FProject, s.Id, mfgSolo, not s.Soloed));
      pbMixer.Invalidate;
      Exit;
    end;

    { pan notch: DrawMixStrip paints its groove at Top+HEADER_H, +-3px tick -
      widened vertically the same way the fader cap's hit rect is, so it's
      actually grabbable. This was previously ONLY settable by typing a
      number into edtMixPan and clicking "Apply strip" - no drag on the strip
      itself did anything, which is the "balance doesn't change" bug. }
    panRect := Rect(FMixStripRects[i].Left + 2, FMixStripRects[i].Top + HEADER_H - 5,
      FMixStripRects[i].Right - 2, FMixStripRects[i].Top + HEADER_H + 5);
    if PtInRect(panRect, Point(X, Y)) then
    begin
      FMixDragMode := mdmPan;
      FMixDragStripId := s.Id;
      pbMixerMouseMove(pbMixer, Shift, X, Y);   { apply immediately, not just on the first move }
      Exit;
    end;

    { fader column: press-and-drag sets the fader live (see pbMixerMouseMove) -
      widened past the painted cap so it is actually easy to grab }
    centerX := (FMixStripRects[i].Left + FMixStripRects[i].Right) div 2;
    bodyTop := FMixStripRects[i].Top + HEADER_H + 6;
    bodyBottom := FMixStripRects[i].Bottom - FOOTER_H;
    if bodyBottom < bodyTop + 10 then bodyBottom := bodyTop + 10;
    faderRect := Rect(centerX - 20, bodyTop, centerX + 4, bodyBottom);
    if PtInRect(faderRect, Point(X, Y)) then
    begin
      FMixDragMode := mdmFader;
      FMixDragStripId := s.Id;
      pbMixerMouseMove(pbMixer, Shift, X, Y);   { apply immediately, not just on the first move }
    end;
    Exit;
  end;
end;

procedure TfrmMain.pbMixerMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
const
  HEADER_H = 34;
  FOOTER_H = 100;   { must match DrawMixStrip }
var
  i, bodyTop, bodyBottom: Integer;
  frac, db, pan: Double;
  s: TMixStrip;
begin
  if not (FMixDragMode in [mdmFader, mdmPan]) or (FProject = nil) then Exit;
  s := FProject.Mixer.StripById(FMixDragStripId);
  if s = nil then Exit;
  i := 0;
  while (i <= High(FMixStripIds)) and (FMixStripIds[i] <> FMixDragStripId) do Inc(i);
  if i > High(FMixStripIds) then Exit;

  if FMixDragMode = mdmFader then
  begin
    bodyTop := FMixStripRects[i].Top + HEADER_H + 6;
    bodyBottom := FMixStripRects[i].Bottom - FOOTER_H;
    if bodyBottom < bodyTop + 10 then bodyBottom := bodyTop + 10;
    frac := 1.0 - (Y - bodyTop) / Double(bodyBottom - bodyTop);
    if frac < 0 then frac := 0 else if frac > 1 then frac := 1;
    db := frac * 72.0 - 60.0;   { matches DrawMixStrip's fader-cap mapping exactly }

    { A real, undo-safe, RT-wired gain control: TSetMixStripFloatCommand feeds
      TMixerModel.FaderDb, which TMixerProcessor.ProcessStrip reads and ramps
      click-free every block (see UDAW.Mixer.Engine) - this is not a slider
      that merely repaints a number. Repeated Perform calls during one drag
      merge into a single undo step via TSetMixStripFloatCommand.AbsorbNext. }
    FCmds.Perform(TSetMixStripFloatCommand.Create(FProject, s.Id, mffFader, db));
    if FTlPlaying and (s.AutomationMode in [amTouch, amLatch, amWrite]) then
      FCmds.Perform(TAddAutomationPointCommand.Create(FProject, s.Id, apFader,
        FProject.Timeline.PlayheadSeconds, db));
  end
  else   { mdmPan: horizontal drag along the pan notch, matching DrawMixStrip's
           panX = Left + 4 + (Pan + 1) / 2 * (Width - 14) mapping, inverted }
  begin
    frac := (X - (FMixStripRects[i].Left + 4)) / Double(FMixStripRects[i].Right - 4 -
      (FMixStripRects[i].Left + 4));
    if frac < 0 then frac := 0 else if frac > 1 then frac := 1;
    pan := frac * 2.0 - 1.0;

    { Same real, undo-safe, RT-wired path as the fader above - previously the
      ONLY way to change pan was typing into edtMixPan and clicking "Apply
      strip"; nothing on the strip itself was interactive. }
    FCmds.Perform(TSetMixStripFloatCommand.Create(FProject, s.Id, mffPan, pan));
    if FTlPlaying and (s.AutomationMode in [amTouch, amLatch, amWrite]) then
      FCmds.Perform(TAddAutomationPointCommand.Create(FProject, s.Id, apPan,
        FProject.Timeline.PlayheadSeconds, pan));
  end;
  pbMixer.Invalidate;
end;

procedure TfrmMain.pbMixerMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  i, targetIdx: Integer;
begin
  if FProject = nil then
  begin
    FMixDragMode := mdmNone;
    Exit;
  end;
  case FMixDragMode of
    mdmReorderStrip:
      begin
        targetIdx := FProject.Mixer.IndexOfStripId(FMixDragStripId);
        for i := 0 to High(FMixStripRects) do
          if (X >= FMixStripRects[i].Left) and (X < FMixStripRects[i].Right) then
          begin
            targetIdx := FProject.Mixer.IndexOfStripId(FMixStripIds[i]);
            Break;
          end;
        if targetIdx >= 0 then
          FCmds.Perform(TMoveMixStripCommand.Create(FProject, FMixDragStripId, targetIdx));
        RefreshMixerTab;
      end;
    mdmReorderInsert:
      begin
        for i := 0 to High(FMixInsertDotRects) do
          if (FMixInsertDotStripId[i] = FMixDragStripId) and
             PtInRect(FMixInsertDotRects[i], Point(X, Y)) then
          begin
            if FMixInsertDotIndex[i] <> FMixDragInsertIndex then
              FCmds.Perform(TMoveMixInsertCommand.Create(FProject, FMixDragStripId,
                FMixDragInsertIndex, FMixInsertDotIndex[i]));
            Break;
          end;
        RefreshMixerTab;
      end;
  end;
  FMixDragMode := mdmNone;
end;

{ Double-click an insert dot: open TfrmMixInsertParams on that specific
  insert's params (see FMixInsertDotRects/FMixInsertDotStripId/
  FMixInsertDotIndex, populated by the most recent DrawMixStrip). VST2
  inserts are excluded - TfrmVST2Editor already hosts a real plugin instance
  for those (btnMixEditVSTClick); this generic editor only understands the
  plain key=value contract used by UDAW's own DSP node kinds. }
procedure TfrmMain.pbMixerDblClick(Sender: TObject);
var
  i: Integer;
  pt: TPoint;
  s: TMixStrip;
  ins: TMixInsert;
  newParams, disp, initialParams: string;
  sc: Integer;
begin
  if FProject = nil then Exit;
  pt := pbMixer.ScreenToClient(Mouse.CursorPos);
  for i := 0 to High(FMixInsertDotRects) do
  begin
    if not PtInRect(FMixInsertDotRects[i], pt) then Continue;
    s := FProject.Mixer.StripById(FMixInsertDotStripId[i]);
    if s = nil then Exit;
    if (FMixInsertDotIndex[i] < 0) or (FMixInsertDotIndex[i] >= s.InsertCount) then Exit;
    ins := s.GetInsert(FMixInsertDotIndex[i]);
    if SameText(ins.Kind, 'vst2') then
    begin
      MessageDlg('This is a VST plugin insert - use "Edit VST..." to open its ' +
        'parameter/editor window.', mtInformation, [mbOK], 0);
      Exit;
    end;
    disp := MixInsertKindDisplay(ins.Kind, ins.Params);
    { see ExtractSidechainParam's comment: the current sidechain source (if
      any) is surfaced as one more editable "sidechain=<stripId>" row rather
      than a dedicated control. }
    initialParams := ins.Params;
    if ins.SidechainStripId <> 0 then
    begin
      if initialParams <> '' then initialParams := initialParams + ';';
      initialParams := initialParams + 'sidechain=' + IntToStr(ins.SidechainStripId);
    end;
    if TfrmMixInsertParams.Edit(Self, ins.Kind, disp, initialParams, newParams) then
    begin
      sc := ExtractSidechainParam(newParams);
      FCmds.Perform(TSetMixInsertParamsCommand.Create(FProject, s.Id,
        FMixInsertDotIndex[i], newParams));
      if (sc >= 0) and (sc <> ins.SidechainStripId) then
        FCmds.Perform(TSetMixInsertSidechainCommand.Create(FProject, s.Id,
          FMixInsertDotIndex[i], sc));
      RefreshMixerTab;
    end;
    Exit;
  end;
end;

{ Menu Enabled/Caption sync happens here, right before the popup shows - never
  from a per-tick path. tmrUITimer only ever calls pbMixer.Invalidate (a cheap
  repaint of live meters) while tabMixer is active, guarded by
  FMenuLoopActive, exactly mirroring pmTimelinePopup / SyncTimelineMenuState -
  see that pair's header comments for the flicker/stale-menu bug this avoids. }
procedure TfrmMain.pmMixerPopup(Sender: TObject);
var
  s: TMixStrip;
begin
  if FProject = nil then Exit;
  s := FProject.Mixer.StripById(SelectedMixStripId);
  pmMixRemove.Enabled := (s <> nil) and (s.Kind <> skMaster);
  pmMixUndo.Enabled := FCmds.CanUndo;
  pmMixRedo.Enabled := FCmds.CanRedo;
  if FCmds.CanUndo then pmMixUndo.Caption := 'Undo: ' + FCmds.UndoDescription
  else pmMixUndo.Caption := 'Undo';
  if FCmds.CanRedo then pmMixRedo.Caption := 'Redo: ' + FCmds.RedoDescription
  else pmMixRedo.Caption := 'Redo';
end;

{ True if AStrip already carries a VST2 insert pointing at the same plugin
  file (compared by its base64-encoded path, same key TAddMixInsertCommand
  stores it under) - dropping/adding the same plugin onto a strip a second
  time should be a no-op, not a duplicate insert. }
function TfrmMain.MixStripHasVst2Insert(AStrip: TMixStrip; const APathB64: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if AStrip = nil then Exit;
  for i := 0 to AStrip.InsertCount - 1 do
    if SameText(AStrip.GetInsert(i).Kind, 'vst2') and
       SameText(MixInsertKV(AStrip.GetInsert(i).Params, 'path'), APathB64) then
      Exit(True);
end;

function TfrmMain.ProbeVst2File(const APath: string; out AParamCount: Integer;
  out AError: string): Boolean;
var
  host: TVST2Host;
begin
  { scan-only: confirm this DLL is really a VST2 effect before it becomes an
    insert - a bad/incompatible DLL is rejected here, not silently accepted.
    Shared by btnMixAddVSTClick (file-dialog path) and pbMixerDragDrop
    (Browser-tab drag path) so the same safety check guards both. }
  Result := True;
  AParamCount := 0;
  AError := '';
  host := TVST2Host.Create;
  try
    try
      host.LoadOnly(APath);
      AParamCount := host.ParamCount;
    except
      on E: Exception do
      begin
        Result := False;
        AError := E.Message;
      end;
    end;
  finally
    host.Free;
  end;
end;

{ Modulator system menu (Mixer > Modulation). Modulators are LFO / smooth
  random / 16-step / envelope follower / macro sources (UDAW.Mixer.Modulation);
  a route sends one to the selected strip's fader (dB), pan or a hosted VST2
  plugin parameter. They are evaluated per audio block in the mixer engine, so
  live playback and export agree, and they are saved with the mixer. }
procedure TfrmMain.MixModMenuClick(Sender: TObject);
var
  ms: TModulationSet;
  m: TModulator;
  r: TModRoute;
  txt, tgt: string;
  parts: TArray<string>;
  i, modNo: Integer;
  fs: TFormatSettings;
  sb: TStringBuilder;
begin
  if FProject = nil then Exit;
  fs := TFormatSettings.Invariant;
  ms := FProject.Mixer.Modulation;
  ms.Bpm := FProject.TempoBPM;
  case TMenuItem(Sender).Tag of
    1: begin
         txt := 'sine 1';
         if not PromptValueBelow('LFO modulator',
           'Shape and rate in Hz, e.g. "sine 1.5" (shapes: sine, triangle, saw, square, sh):', txt) then Exit;
         parts := Trim(txt).Split([' ']);
         m := ms.AddModulator(mkLfo, Format('LFO %d', [ms.ModCount + 1]));
         if Length(parts) > 0 then
           if SameText(parts[0], 'triangle') then m.Shape := lsTriangle
           else if SameText(parts[0], 'saw') then m.Shape := lsSaw
           else if SameText(parts[0], 'square') then m.Shape := lsSquare
           else if SameText(parts[0], 'sh') then m.Shape := lsSampleHold
           else m.Shape := lsSine;
         if Length(parts) > 1 then m.RateHz := Max(StrToFloatDef(parts[1], 1, fs), 0.01);
       end;
    2: begin
         txt := '2';
         if not PromptValueBelow('Random modulator', 'New random target per second (rate in Hz):', txt) then Exit;
         m := ms.AddModulator(mkRandom, Format('Random %d', [ms.ModCount + 1]));
         m.RateHz := Max(StrToFloatDef(Trim(txt), 2, fs), 0.01);
       end;
    3: begin
         txt := '1 -1 0.5 -0.5 1 0 0.5 -1';
         if not PromptValueBelow('Step modulator',
           'Rate in steps/second, then up to 16 step values from -1 to 1:', txt) then Exit;
         parts := Trim(txt).Split([' ']);
         m := ms.AddModulator(mkSteps, Format('Steps %d', [ms.ModCount + 1]));
         if Length(parts) > 0 then m.RateHz := Max(StrToFloatDef(parts[0], 4, fs), 0.01);
         m.StepCount := EnsureRange(Length(parts) - 1, 1, 16);
         for i := 1 to Min(Length(parts) - 1, 16) do
           m.Steps[i - 1] := EnsureRange(StrToFloatDef(parts[i], 0, fs), -1.0, 1.0);
       end;
    4: begin
         if SelectedMixStripId = 0 then
         begin
           memMix.Lines.Insert(0, 'Modulation: select a strip to follow first.');
           Exit;
         end;
         m := ms.AddModulator(mkFollower, Format('Follower of strip %d', [SelectedMixStripId]));
         m.FollowStripId := SelectedMixStripId;
       end;
    5: begin
         txt := '0';
         if not PromptValueBelow('Macro knob', 'Value from -1 to 1:', txt) then Exit;
         m := ms.AddModulator(mkMacro, Format('Macro %d', [ms.ModCount + 1]));
         m.Value := EnsureRange(StrToFloatDef(Trim(txt), 0, fs), -1.0, 1.0);
       end;
    6: begin
         if SelectedMixStripId = 0 then
         begin
           memMix.Lines.Insert(0, 'Modulation: select the target strip first.');
           Exit;
         end;
         if ms.ModCount = 0 then
         begin
           memMix.Lines.Insert(0, 'Modulation: add a modulator first.');
           Exit;
         end;
         txt := '1 fader 3';
         if not PromptValueBelow('Route modulator',
           'modulator# target amount  -  target: fader (amount in dB), pan (amount -1..1), ' +
           'or iN:pM = insert N (1-based), VST2 parameter M (amount 0..1, optional 4th value = base 0..1):', txt) then Exit;
         parts := Trim(txt).Split([' ']);
         if Length(parts) < 3 then
         begin
           memMix.Lines.Insert(0, 'Modulation: expected "modulator# target amount".');
           Exit;
         end;
         modNo := StrToIntDef(parts[0], 0) - 1;
         if (modNo < 0) or (modNo >= ms.ModCount) then
         begin
           memMix.Lines.Insert(0, 'Modulation: no such modulator number.');
           Exit;
         end;
         tgt := LowerCase(parts[1]);
         r.ModIndex := modNo;
         r.StripId := SelectedMixStripId;
         r.TargetIndex := 0;
         r.SubIndex := 0;
         r.Base := 0.5;
         r.Amount := StrToFloatDef(parts[2], 0, fs);
         if tgt = 'fader' then r.Param := apFader
         else if tgt = 'pan' then r.Param := apPan
         else if (Length(tgt) > 3) and (tgt[1] = 'i') and (Pos(':p', tgt) > 0) then
         begin
           r.Param := apInsertParam;
           r.TargetIndex := StrToIntDef(Copy(tgt, 2, Pos(':p', tgt) - 2), 1) - 1;
           r.SubIndex := StrToIntDef(Copy(tgt, Pos(':p', tgt) + 2, MaxInt), 0);
           if Length(parts) > 3 then r.Base := EnsureRange(StrToFloatDef(parts[3], 0.5, fs), 0.0, 1.0);
         end
         else
         begin
           memMix.Lines.Insert(0, 'Modulation: target must be fader, pan or iN:pM.');
           Exit;
         end;
         ms.AddRoute(r);
       end;
    7: begin
         sb := TStringBuilder.Create;
         try
           for i := 0 to ms.ModCount - 1 do
             sb.AppendFormat('#%d  %s (%s)'#13#10, [i + 1, ms.GetMod(i).Name, ModKindId(ms.GetMod(i).Kind)]);
           for i := 0 to ms.RouteCount - 1 do
             sb.AppendFormat('route: modulator %d -> strip %d, %s, amount %s'#13#10,
               [ms.GetRoute(i).ModIndex + 1, ms.GetRoute(i).StripId,
                AutomationParamId(ms.GetRoute(i).Param),
                FloatToStr(ms.GetRoute(i).Amount, fs)]);
           if sb.Length = 0 then sb.Append('No modulators yet.');
           MessageDlg(sb.ToString, mtInformation, [mbOK], 0);
         finally
           sb.Free;
         end;
         Exit;
       end;
    8: begin
         ms.Clear;
         memMix.Lines.Insert(0, 'Modulation: all modulators and routes removed.');
       end;
  else
    Exit;
  end;
  FProject.Touch;
  memMix.Lines.Insert(0, Format('Modulation: %d modulator(s), %d route(s).', [ms.ModCount, ms.RouteCount]));
end;

procedure TfrmMain.btnMixAddVSTClick(Sender: TObject);
var
  pathB64, loadError, ext, plugName: string;
  paramCount: Integer;
  clapProbe: TCLAPHost;
  vst3Probe: TVST3Host;
begin
  if (FProject = nil) or (SelectedMixStripId = 0) then Exit;
  if not dlgOpenVst.Execute then Exit;
  ext := LowerCase(ExtractFileExt(dlgOpenVst.FileName));
  if (ext = '.clap') or (ext = '.vst3') then
  begin
    { CLAP / VST3: probe by really loading the module, then insert by kind }
    try
      if ext = '.clap' then
      begin
        clapProbe := TCLAPHost.Create;
        try
          clapProbe.LoadOnly(dlgOpenVst.FileName);
          plugName := clapProbe.EffectName;
        finally
          clapProbe.Free;
        end;
      end
      else
      begin
        vst3Probe := TVST3Host.Create;
        try
          vst3Probe.LoadOnly(dlgOpenVst.FileName);
          plugName := vst3Probe.EffectName;
        finally
          vst3Probe.Free;
        end;
      end;
    except
      on E: Exception do
      begin
        MessageDlg('Not a usable plugin:'#13#10 + dlgOpenVst.FileName + #13#10#13#10 + E.Message,
          mtError, [mbOK], 0);
        Exit;
      end;
    end;
    pathB64 := TNetEncoding.Base64.EncodeBytesToString(TEncoding.UTF8.GetBytes(dlgOpenVst.FileName));
    FCmds.Perform(TAddMixInsertCommand.Create(FProject, SelectedMixStripId,
      Copy(ext, 2, MaxInt), Format('path=%s;state=', [pathB64]), -1,
      IfThen(plugName <> '', plugName, ExtractFileName(dlgOpenVst.FileName))));
    RefreshMixerTab;
    Exit;
  end;

  pathB64 := TNetEncoding.Base64.EncodeBytesToString(TEncoding.UTF8.GetBytes(dlgOpenVst.FileName));
  if MixStripHasVst2Insert(FProject.Mixer.StripById(SelectedMixStripId), pathB64) then
  begin
    MessageDlg('That plugin is already on this strip.', mtInformation, [mbOK], 0);
    Exit;
  end;

  if not ProbeVst2File(dlgOpenVst.FileName, paramCount, loadError) then
  begin
    MessageDlg('Not a usable VST2 plugin:'#13#10 + dlgOpenVst.FileName + #13#10#13#10 + loadError,
      mtError, [mbOK], 0);
    Exit;
  end;

  pathB64 := TNetEncoding.Base64.EncodeBytesToString(TEncoding.UTF8.GetBytes(dlgOpenVst.FileName));
  FCmds.Perform(TAddMixInsertCommand.Create(FProject, SelectedMixStripId, 'vst2',
    Format('path=%s;state=;paramcount=%d', [pathB64, paramCount]), -1,
    ExtractFileName(dlgOpenVst.FileName)));
  RefreshMixerTab;
end;

function TfrmMain.OpenVST2EditorForInsert(AStripId, AIndex: Integer): Boolean;
var
  s: TMixStrip;
  ins: TMixInsert;
  pathB64, stateB64, path, key: string;
  frm: TfrmVST2Editor;
  capturedStripId, capturedIndex, capturedParamCount: Integer;
  capturedPathB64: string;
begin
  Result := False;
  if FProject = nil then Exit;
  s := FProject.Mixer.StripById(AStripId);
  if s = nil then Exit;
  if (AIndex < 0) or (AIndex >= s.InsertCount) then Exit;
  ins := s.GetInsert(AIndex);
  if not SameText(ins.Kind, 'vst2') then Exit;

  pathB64 := MixInsertKV(ins.Params, 'path');
  stateB64 := MixInsertKV(ins.Params, 'state');
  path := TEncoding.UTF8.GetString(TNetEncoding.Base64.DecodeStringToBytes(pathB64));

  capturedStripId := s.Id;
  capturedIndex := AIndex;
  capturedPathB64 := pathB64;
  capturedParamCount := StrToIntDef(MixInsertKV(ins.Params, 'paramcount'), 0);
  key := Format('%s%d:%d', [WINKEY_VST2_PREFIX, capturedStripId, capturedIndex]);

  frm := TfrmVST2Editor.Create(Self);
  { This scratch host is separate from whatever TMixerProcessor node exists
    at render time (see UDAW.UI.VST2Editor's header comment) - Save writes
    the edited state back into the mixer model as an ordinary undo-safe
    TSetMixInsertParamsCommand, same as the AI mastering assistant's insert
    tuning. }
  if not frm.OpenPlugin(path, stateB64, FProject.SampleRate, UDAW_DEFAULT_BUFFER_FRAMES,
    FProject.Channels,
    procedure(ANewState: string)
    begin
      FCmds.Perform(TSetMixInsertParamsCommand.Create(FProject, capturedStripId, capturedIndex,
        Format('path=%s;state=%s;paramcount=%d',
          [capturedPathB64, ANewState, capturedParamCount])));
      RefreshMixerTab;
    end) then
  begin
    frm.Free;
    Exit;
  end;
  frm.WindowKey := key;
  frm.OnEditorClosing := VST2EditorClosing;
  FOpenVST2Editors.Add(frm);
  ApplySavedGeometry(frm, FProject.Windows.Find(key));
  frm.Show;
  Result := True;
end;

procedure TfrmMain.VST2EditorClosing(Sender: TObject);
var
  frm: TfrmVST2Editor;
begin
  { See LogViewerFormClose: the user closing this plugin editor means "don't
    reopen it next time" - forget its remembered geometry rather than
    updating it, or it would keep coming back on every future project load.
    An editor still open when the project is saved/closed is captured
    separately by CaptureOpenWindowLayout. }
  frm := TfrmVST2Editor(Sender);
  if (FProject <> nil) and (frm.WindowKey <> '') then
    FProject.Windows.Remove(frm.WindowKey);
  if FOpenVST2Editors <> nil then
    FOpenVST2Editors.Remove(frm);
end;

procedure TfrmMain.btnMixEditVSTClick(Sender: TObject);
var
  s: TMixStrip;
  i, idx: Integer;
begin
  if FProject = nil then Exit;
  s := FProject.Mixer.StripById(SelectedMixStripId);
  if s = nil then Exit;
  idx := -1;
  for i := s.InsertCount - 1 downto 0 do
    if SameText(s.GetInsert(i).Kind, 'vst2') then
    begin
      idx := i;
      Break;
    end;
  if idx < 0 then
  begin
    MessageDlg('The selected strip has no VST plugin insert. Use "Add VST..." first.',
      mtInformation, [mbOK], 0);
    Exit;
  end;
  OpenVST2EditorForInsert(s.Id, idx);
end;

procedure TfrmMain.cboMixAutoParamChange(Sender: TObject);
begin
  if (cboMixAutoParam.ItemIndex >= 0) and
     (cboMixAutoParam.ItemIndex <= High(FMixAutoParams)) then
  begin
    FMixAutoParam := FMixAutoParams[cboMixAutoParam.ItemIndex];
    FMixAutoTarget := FMixAutoTargets[cboMixAutoParam.ItemIndex];
    FMixAutoSub := FMixAutoSubs[cboMixAutoParam.ItemIndex];
  end;
  pbMixAuto.Invalidate;
end;

procedure TfrmMain.cboMixAutoModeChange(Sender: TObject);
const
  MODES: array[0..4] of TMixAutomationMode = (amOff, amRead, amTouch, amLatch, amWrite);
begin
  if (FProject = nil) or (SelectedMixStripId = 0) or FMixRefreshing then Exit;
  if cboMixAutoMode.ItemIndex in [0..4] then
    FCmds.Perform(TSetMixStripAutoModeCommand.Create(FProject, SelectedMixStripId,
      MODES[cboMixAutoMode.ItemIndex]));
end;

procedure TfrmMain.tbMixZoomChange(Sender: TObject);
begin
  { strip-width zoom (see FMixZoomFactor's declaration); tbMixZoom ranges
    5..20 over Position/10.0 => 0.5x..2.0x, persisted across sessions. }
  FMixZoomFactor := tbMixZoom.Position / 10.0;
  if (App <> nil) and (App.Config <> nil) then
    App.Config.SetFloat(CFG_SEC_UI, CFG_UI_MIXER_STRIP_WIDTH, FMixZoomFactor);
  pbMixer.Invalidate;
end;

procedure TfrmMain.btnMixMeterApplyClick(Sender: TObject);
var
  holdMs, decayDb: Double;
  fs: TFormatSettings;
begin
  if FProject = nil then Exit;
  fs := TFormatSettings.Invariant;
  if not TryStrToFloat(StringReplace(edtMixMeterHold.Text, ',', '.', [rfReplaceAll]),
    holdMs, fs) then holdMs := MIX_METER_HOLD_MS_DEFAULT;
  if not TryStrToFloat(StringReplace(edtMixMeterDecay.Text, ',', '.', [rfReplaceAll]),
    decayDb, fs) then decayDb := MIX_METER_HOLD_DECAY_DEFAULT;
  FCmds.Perform(TSetMixMeterConfigCommand.Create(FProject, holdMs, decayDb));
  RefreshMixerTab;
end;

procedure TfrmMain.pbMixAutoPaint(Sender: TObject);
var
  cv: TCanvas;
  w, h, i, x, y: Integer;
  s: TMixStrip;
  lane: TAutomationLane;
  totalSec: Double;
  pt: TAutomationPoint;
  theme: TUDAWTheme;
  lo, hi: Double;
begin
  w := pbMixAuto.Width;
  h := pbMixAuto.Height;
  if (w <= 0) or (h <= 0) then Exit;
  { offscreen-bitmap-then-blit, mirrors pbMixerPaint/FMixBuffer - this box
    previously drew straight to pbMixAuto.Canvas and was the confirmed
    flicker source inside the Mixer tab (tmrUITimer repaints it constantly
    while a strip is selected). The try/finally guarantees the blit still
    happens on every early Exit below (no lane, no project, no strip). }
  FMixAutoBuffer.SetSize(w, h);
  cv := FMixAutoBuffer.Canvas;
  try
    theme := CurrentTheme;
    cv.Brush.Style := bsSolid;
    cv.Brush.Color := theme.PanelBackground;
    cv.FillRect(Rect(0, 0, w, h));
    if (FProject = nil) or (SelectedMixStripId = 0) then Exit;
    s := FProject.Mixer.StripById(SelectedMixStripId);
    if s = nil then Exit;

    cv.Brush.Style := bsClear;
    cv.Font.Color := theme.SecondaryText;
    cv.TextOut(4, 2, Format(
      '%s automation - "%s" [%s] - left-click: add/move point, right-click: delete nearest',
      [cboMixAutoParam.Text, s.Name, MixAutomationModeId(s.AutomationMode)]));

    totalSec := FProject.Timeline.TotalDurationSeconds;
    if totalSec < 1.0 then totalSec := 1.0;
    case FMixAutoParam of
      apFader, apSendGain: begin lo := MIX_MIN_DB; hi := MIX_MAX_DB; end;
      apPan: begin lo := -1.0; hi := 1.0; end;
    else
      begin lo := 0.0; hi := 1.0; end;
    end;

    if FMixAutoRegionActive then
    begin
      cv.Brush.Style := bsSolid;
      cv.Brush.Color := theme.Accent;
      { no alpha on TCanvas: draw the region as a thin band under the header
        text plus edge lines so the lane's points stay visible }
      cv.FillRect(Rect(Min(FMixAutoRegionX0, FMixAutoRegionX1), 16,
        Max(FMixAutoRegionX0, FMixAutoRegionX1), 20));
      cv.Pen.Color := theme.Accent;
      cv.MoveTo(FMixAutoRegionX0, 16); cv.LineTo(FMixAutoRegionX0, h);
      cv.MoveTo(FMixAutoRegionX1, 16); cv.LineTo(FMixAutoRegionX1, h);
      cv.Brush.Style := bsClear;
    end;

    x := Round(4 + (w - 8) * (FProject.Timeline.PlayheadSeconds / totalSec));
    cv.Pen.Color := theme.Accent;
    cv.MoveTo(x, 16); cv.LineTo(x, h);

    lane := FProject.Mixer.Automation.LaneFor(s.Id, FMixAutoParam, False,
      FMixAutoTarget, FMixAutoSub);
    if (lane = nil) or (lane.PointCount = 0) then Exit;

    cv.Pen.Color := theme.Text;
    for i := 0 to lane.PointCount - 1 do
    begin
      pt := lane.GetPoint(i);
      x := Round(4 + (w - 8) * (pt.TimeSeconds / totalSec));
      y := 16 + Round((h - 20) * (1.0 - (pt.Value - lo) / (hi - lo)));
      if i = 0 then cv.MoveTo(x, y) else cv.LineTo(x, y);
    end;
    cv.Brush.Style := bsSolid;
    cv.Brush.Color := theme.Accent;
    for i := 0 to lane.PointCount - 1 do
    begin
      pt := lane.GetPoint(i);
      x := Round(4 + (w - 8) * (pt.TimeSeconds / totalSec));
      y := 16 + Round((h - 20) * (1.0 - (pt.Value - lo) / (hi - lo)));
      cv.FillRect(Rect(x - 3, y - 3, x + 3, y + 3));
    end;
  finally
    pbMixAuto.Canvas.Draw(0, 0, FMixAutoBuffer);
  end;
end;

procedure TfrmMain.pbMixAutoMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  w, h: Integer;
  s: TMixStrip;
  totalSec, t, v, lo, hi, tol: Double;
begin
  if (FProject = nil) or (SelectedMixStripId = 0) then Exit;
  s := FProject.Mixer.StripById(SelectedMixStripId);
  if s = nil then Exit;
  w := pbMixAuto.Width;
  h := pbMixAuto.Height;
  if (w <= 8) or (h <= 20) then Exit;

  totalSec := FProject.Timeline.TotalDurationSeconds;
  if totalSec < 1.0 then totalSec := 1.0;
  t := (X - 4) / Double(w - 8) * totalSec;
  if t < 0 then t := 0;
  case FMixAutoParam of
    apFader, apSendGain: begin lo := MIX_MIN_DB; hi := MIX_MAX_DB; end;
    apPan: begin lo := -1.0; hi := 1.0; end;
  else
    begin lo := 0.0; hi := 1.0; end;
  end;
  v := lo + (hi - lo) * (1.0 - (Y - 16) / Double(h - 20));
  if v < lo then v := lo else if v > hi then v := hi;

  FMixAutoRegionActive := False;
  if (Button = mbLeft) and (ssCtrl in Shift) then
  begin
    FMixAutoRegionDragging := True;
    FMixAutoRegionX0 := X;
    FMixAutoRegionX1 := X;
    pbMixAuto.Invalidate;
    Exit;
  end;
  if Button = mbLeft then
    FCmds.Perform(TAddAutomationPointCommand.Create(FProject, s.Id, FMixAutoParam,
      t, v, FMixAutoTarget, FMixAutoSub))
  else if Button = mbRight then
  begin
    tol := totalSec / Double(w - 8) * 4;   { ~4 px worth of time tolerance }
    FCmds.Perform(TRemoveAutomationPointCommand.Create(FProject, s.Id, FMixAutoParam,
      t, tol, FMixAutoTarget, FMixAutoSub));
  end;
  pbMixAuto.Invalidate;
end;

procedure TfrmMain.pbMixAutoMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
begin
  if not FMixAutoRegionDragging then Exit;
  FMixAutoRegionX1 := X;
  FMixAutoRegionActive := Abs(FMixAutoRegionX1 - FMixAutoRegionX0) >= 3;
  pbMixAuto.Invalidate;
end;

procedure TfrmMain.pbMixAutoMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  FMixAutoRegionDragging := False;
end;

{ ================= Tracker tab ================= }

function TfrmMain.SelectedTrackerPattern: Integer;
begin
  Result := cboTrkPattern.ItemIndex;
  if Result < 0 then Result := 0;
end;

procedure TfrmMain.RefreshTrackerTab(AFull: Boolean);
var
  m: TTrackerModule;
  i, keep, visSeqSteps, playRow, playOrder: Integer;
  pat: TTrackerPattern;
  cell: TTrackerCell;
begin
  if (FProject = nil) or FTrkRefreshing then Exit;
  FTrkRefreshing := True;
  try
    m := FProject.Tracker;
    { while playing, the editor view follows the transport (plan requirement:
      "the pattern grid needs to move whilst playing showing ... pattern");
      once stopped, the last-viewed pattern (whatever the user picked, incl.
      a jump from the sequence strip) sticks. }
    if FTrkPlaying and (FTrkPlayer <> nil) and (FTrkPlayer.CurrentPatternIndex >= 0) then
      keep := FTrkPlayer.CurrentPatternIndex
    else
      keep := SelectedTrackerPattern;

    { AFull=False (the once-per-frame call made while the transport is
      running - see tmrUITimer) skips every one of the blocks below that
      rebuilds a whole VCL control or reformats the whole module: rebuilding
      the combobox's Items and resetting the memo's Lines.Text 30 times a
      second is what was making the tracker tab visibly flicker, since each
      of those is a full control repaint, not just the pattern grid's. Only
      the playback readout (cheap, and needed every frame) still updates. }
    if AFull then
    begin
      cboTrkPattern.Items.BeginUpdate;
      try
        cboTrkPattern.Items.Clear;
        for i := 0 to m.PatternCount - 1 do
          cboTrkPattern.Items.Add(Format('Pattern %d  (%d rows)', [i, m.GetPattern(i).Rows]));
      finally
        cboTrkPattern.Items.EndUpdate;
      end;
    end;
    if keep >= cboTrkPattern.Items.Count then keep := cboTrkPattern.Items.Count - 1;
    if keep < 0 then keep := 0;
    if cboTrkPattern.ItemIndex <> keep then
      cboTrkPattern.ItemIndex := keep;

    if AFull then
    begin
      edtTrkSpeed.Text := IntToStr(m.InitialSpeed);
      edtTrkBPM.Text := IntToStr(m.InitialBPM);

      pat := m.GetPattern(SelectedTrackerPattern);
      if pat <> nil then
      begin
        if FTrkSelRow >= pat.Rows then FTrkSelRow := pat.Rows - 1;
        if FTrkSelChn >= pat.Channels then FTrkSelChn := pat.Channels - 1;
        if FTrkSelRow < 0 then FTrkSelRow := 0;
        if FTrkSelChn < 0 then FTrkSelChn := 0;
        cell := pat.GetCell(FTrkSelRow, FTrkSelChn);
        edtTrkNote.Text := NoteName(cell.Note);
        if cell.Instrument = TRK_INSTR_NONE then edtTrkInstr.Text := ''
        else edtTrkInstr.Text := IntToStr(cell.Instrument);
        if cell.Volume > TRK_VOL_MAX then edtTrkVol.Text := ''
        else edtTrkVol.Text := IntToStr(cell.Volume);
        if (cell.Effect = tfxNone) and (cell.Param = 0) then
        begin
          edtTrkEff.Text := '';
          edtTrkParam.Text := '';
        end
        else
        begin
          edtTrkEff.Text := EffectLetter(cell.Effect);
          edtTrkParam.Text := IntToHex(cell.Param, 2);
        end;
      end;

      mnuTrkDelPattern.Enabled := m.PatternCount > 1;
      pmTrkDelPattern.Enabled := m.PatternCount > 1;
      mnuTrkUndo.Enabled := FCmds.CanUndo;
      pmTrkUndo.Enabled := FCmds.CanUndo;
      mnuTrkRedo.Enabled := FCmds.CanRedo;
      pmTrkRedo.Enabled := FCmds.CanRedo;

      { horizontal channel scrollbar: range tracks the pattern's channel
        count vs. how many columns actually fit in pbTracker's width. }
      if pat <> nil then
      begin
        if sbTrkChn.Max <> Max(0, pat.Channels - 1) then
          sbTrkChn.Max := Max(0, pat.Channels - 1);
        if FTrkGridChnScroll > sbTrkChn.Max then FTrkGridChnScroll := sbTrkChn.Max;
        if FTrkGridChnScroll < 0 then FTrkGridChnScroll := 0;
        if sbTrkChn.Position <> FTrkGridChnScroll then
          sbTrkChn.Position := FTrkGridChnScroll;
      end;

      RefreshTrkInstrTab;
    end;
    mnuTrkPlay.Enabled := not FTrkPlaying;
    pmTrkPlay.Enabled := not FTrkPlaying;
    mnuTrkStop.Enabled := FTrkPlaying;
    pmTrkStop.Enabled := FTrkPlaying;

    if FTrkPlaying and (FTrkPlayer <> nil) then
      FTrkPreview := Format(
        'playing: order %d  pattern %d  row %d  tick %d/%d  %d BPM%s',
        [FTrkPlayer.CurrentOrder, FTrkPlayer.CurrentPatternIndex, FTrkPlayer.CurrentRow,
         FTrkPlayer.CurrentTick, FTrkPlayer.Speed, FTrkPlayer.BPM,
         IfThen(FTrkPlayer.SongEnded, '  (ended)', '')]);

    if AFull then
      memTrk.Lines.Text := m.Describe + sLineBreak + sLineBreak +
        Format('selected cell: pattern %d  row %d  channel %d', [SelectedTrackerPattern, FTrkSelRow, FTrkSelChn]) +
        sLineBreak + '--- preview ---' + sLineBreak + FTrkPreview;

    { sequence strip: scrollbar range, and auto-scroll to keep the playing
      step ("where it's up to") in view without fighting a manual scroll
      once stopped. }
    if sbTrkSeq.Max <> Max(0, m.OrderLength - 1) then
      sbTrkSeq.Max := Max(0, m.OrderLength - 1);
    if FTrkSeqScroll > sbTrkSeq.Max then FTrkSeqScroll := sbTrkSeq.Max;
    if FTrkSeqScroll < 0 then FTrkSeqScroll := 0;
    if FTrkPlaying and (FTrkPlayer <> nil) then
    begin
      visSeqSteps := Max(1, (pbTrkSequence.Width div TrkSeqStepWidth));
      if FTrkPlayer.CurrentOrder < FTrkSeqScroll then
        FTrkSeqScroll := FTrkPlayer.CurrentOrder
      else if FTrkPlayer.CurrentOrder >= FTrkSeqScroll + visSeqSteps then
        FTrkSeqScroll := Max(0, FTrkPlayer.CurrentOrder - visSeqSteps + 1);
    end;
    if sbTrkSeq.Position <> FTrkSeqScroll then
      sbTrkSeq.Position := FTrkSeqScroll;
  finally
    FTrkRefreshing := False;
  end;
  playRow := -1;
  playOrder := -1;
  if FTrkPlaying and (FTrkPlayer <> nil) then
  begin
    playRow := FTrkPlayer.CurrentRow;
    playOrder := FTrkPlayer.CurrentOrder;
  end;
  if AFull or (keep <> FTrkLastPattern) or (playRow <> FTrkLastRow) then
    pbTracker.Invalidate;
  if AFull or (keep <> FTrkLastPattern) or (playOrder <> FTrkLastOrder) or
    (FTrkSeqScroll <> FTrkLastScroll) then pbTrkSequence.Invalidate;
  FTrkLastPattern := keep;
  FTrkLastRow := playRow;
  FTrkLastOrder := playOrder;
  FTrkLastScroll := FTrkSeqScroll;
end;

procedure TfrmMain.cboTrkPatternChange(Sender: TObject);
begin
  FTrkGridRowScroll := -1;   // switching patterns resumes auto-follow
  RefreshTrackerTab;
end;

{ Tracker > New > Tracker: discard the current in-memory tracker module and
  start a fresh, empty one (undoable, like an import). }
procedure TfrmMain.mnuTrkNewTrackerClick(Sender: TObject);
begin
  if FProject = nil then Exit;
  if MessageDlg('Discard the current tracker module and start a fresh, empty one?'
    + sLineBreak + 'This can be undone (Tracker > Edit > Undo).',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  if FTrkPlaying then btnTrkStopClick(nil);
  FCmds.Perform(TNewTrackerModuleCommand.Create(FProject));
  FTrkSelRow := 0;
  FTrkSelChn := 0;
  FTrkGridRowScroll := -1;
  FTrkGridChnScroll := 0;
  FTrkPreview := 'new tracker module';
  Logger.Info('ui', 'Tracker module reset to a fresh, empty one');
  RefreshTrackerTab;
end;

procedure TfrmMain.btnTrkApplyXportClick(Sender: TObject);
var
  sp, bp: Integer;
begin
  sp := StrToIntDef(Trim(edtTrkSpeed.Text), FProject.Tracker.InitialSpeed);
  bp := StrToIntDef(Trim(edtTrkBPM.Text), FProject.Tracker.InitialBPM);
  FCmds.Perform(TSetTrackerTransportCommand.Create(FProject, True, sp));
  FCmds.Perform(TSetTrackerTransportCommand.Create(FProject, False, bp));
  RefreshTrackerTab;
end;

procedure TfrmMain.btnTrkAddPatternClick(Sender: TObject);
begin
  FCmds.Perform(TAddTrackerPatternCommand.Create(FProject, TRK_DEFAULT_ROWS));
  RefreshTrackerTab;
end;

procedure TfrmMain.btnTrkDelPatternClick(Sender: TObject);
begin
  try
    FCmds.Perform(TRemoveTrackerPatternCommand.Create(FProject, SelectedTrackerPattern));
  except
    on E: EUDAWError do MessageDlg(E.Message, mtWarning, [mbOK], 0);
  end;
  RefreshTrackerTab;
end;

procedure TfrmMain.btnTrkSetCellClick(Sender: TObject);
var
  cell: TTrackerCell;
  n: Byte;
  iv: Integer;
  eff: TTrackerEffect;
begin
  cell := TTrackerCell.Empty;
  if NoteFromName(Trim(edtTrkNote.Text), n) then cell.Note := n;
  if TryStrToInt(Trim(edtTrkInstr.Text), iv) and (iv > 0) and (iv < 256) then
    cell.Instrument := Byte(iv);
  if TryStrToInt(Trim(edtTrkVol.Text), iv) and (iv >= 0) and (iv <= TRK_VOL_MAX) then
    cell.Volume := Byte(iv);
  if (Trim(edtTrkEff.Text) <> '') and EffectFromLetter(edtTrkEff.Text[1], eff) then
  begin
    cell.Effect := eff;
    if TryStrToInt('$' + Trim(edtTrkParam.Text), iv) then cell.Param := Byte(iv);
  end;
  FCmds.Perform(TSetTrackerCellCommand.Create(FProject, SelectedTrackerPattern,
    FTrkSelRow, FTrkSelChn, cell));
  RefreshTrackerTab;
end;

procedure TfrmMain.btnTrkClearCellClick(Sender: TObject);
begin
  FCmds.Perform(TSetTrackerCellCommand.Create(FProject, SelectedTrackerPattern,
    FTrkSelRow, FTrkSelChn, TTrackerCell.Empty));
  RefreshTrackerTab;
end;

procedure TfrmMain.btnTrkFillDemoClick(Sender: TObject);
var
  m: TTrackerModule;
  insId, r, patIdx: Integer;
  notes: array[0..3] of string;
  cell: TTrackerCell;
  nb: Byte;
begin
  m := FProject.Tracker;
  patIdx := SelectedTrackerPattern;
  { one sine instrument (undoable), then a C-E-G-C arpeggio down channel 0 }
  FCmds.Perform(TAddTrackerInstrumentCommand.Create(FProject, 'Demo Sine', 440.0, 0.5));
  insId := m.InstrumentCount;
  notes[0] := 'C-4'; notes[1] := 'E-4'; notes[2] := 'G-4'; notes[3] := 'C-5';
  for r := 0 to 3 do
  begin
    cell := TTrackerCell.Empty;
    if NoteFromName(notes[r], nb) then cell.Note := nb;
    cell.Instrument := Byte(insId);
    FCmds.Perform(TSetTrackerCellCommand.Create(FProject, patIdx, r * 4, 0, cell));
  end;
  RefreshTrackerTab;
end;

procedure TfrmMain.btnTrkPlayClick(Sender: TObject);
begin
  if (App = nil) or (App.Audio = nil) then Exit;

  App.Audio.ClearSource;
  FreeAndNil(FTrkPlayer);

  FTrkPlayer := TTrackerPlayer.Create(FProject.Tracker);
  FTrkPlayer.LoopSong := True;
  FGraphPlaying := False;
  FWavPlaying := False;
  StopTimelinePlayback;
  App.Audio.SetSource(FTrkPlayer.AsSource);
  FTrkPlaying := True;
  FTrkPreview := Format('playing through the engine: speed %d, %d BPM (looping)',
    [FTrkPlayer.Speed, FTrkPlayer.BPM]);
  { the pattern-grid / sequence-strip readout needs to move smoothly, not
    once every half second - raise tmrUI's rate to near-frame while the
    transport is running (restored in btnTrkStopClick); tmrUITimer calls
    RefreshTrackerTab(False) checks for changed rows/orders; buffered drawing
    presents each complete frame without rebuilding controls. }
  tmrUI.Interval := TRK_UI_PLAY_INTERVAL_MS;
  RefreshTrackerTab;
end;

procedure TfrmMain.btnTrkStopClick(Sender: TObject);
begin
  if (App <> nil) and (App.Audio <> nil) then
    App.Audio.ClearSource;
  FTrkPlaying := False;
  FreeAndNil(FTrkPlayer);
  FTrkPreview := '(stopped)';
  tmrUI.Interval := TRK_UI_IDLE_INTERVAL_MS;
  RefreshTrackerTab;
end;

procedure TfrmMain.btnTrkUndoClick(Sender: TObject);
begin
  FCmds.Undo;
  RefreshTrackerTab;
end;

procedure TfrmMain.btnTrkRedoClick(Sender: TObject);
begin
  FCmds.Redo;
  RefreshTrackerTab;
end;

procedure TfrmMain.btnTrkImportModClick(Sender: TObject);
var
  fs: TFileStream;
  data: TBytes;
  info: TModImportInfo;
begin
  if not dlgOpenMod.Execute then Exit;
  if not FileLooksLikeMod(dlgOpenMod.FileName) then
  begin
    MessageDlg('That file is not a recognisable ProTracker / Soundtracker MOD:'
      + sLineBreak + dlgOpenMod.FileName, mtWarning, [mbOK], 0);
    Exit;
  end;
  try
    fs := TFileStream.Create(dlgOpenMod.FileName, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(data, fs.Size);
      if Length(data) > 0 then fs.ReadBuffer(data[0], Length(data));
    finally
      fs.Free;
    end;
    { parse once for the report, then import as an undoable command }
    ModToModule(data, info).Free;
    FCmds.Perform(TImportModCommand.Create(FProject, data,
      ExtractFileName(dlgOpenMod.FileName)));
    FTrkPreview := 'imported ' + ExtractFileName(dlgOpenMod.FileName) + sLineBreak
      + info.Summary;
    Logger.Info('ui', 'MOD imported: ' + dlgOpenMod.FileName);
  except
    on E: Exception do
      MessageDlg('MOD import failed:' + sLineBreak + E.Message, mtError, [mbOK], 0);
  end;
  FTrkSelRow := 0;
  FTrkSelChn := 0;
  FTrkGridRowScroll := -1;
  FTrkGridChnScroll := 0;
  RefreshTrackerTab;
end;

procedure TfrmMain.btnTrkExportModClick(Sender: TObject);
var
  issues: TArray<string>;
  msg: string;
  i: Integer;
begin
  if not RequireRegistration('Exporting a .mod') then Exit;
  issues := ModExportIssues(FProject.Tracker);
  if Length(issues) > 0 then
  begin
    msg := 'This project''s tracker module cannot be fully represented in MOD:'
      + sLineBreak + sLineBreak;
    for i := 0 to High(issues) do
      msg := msg + '  - ' + issues[i] + sLineBreak;
    msg := msg + sLineBreak + 'Export anyway (best effort)?';
    if MessageDlg(msg, mtWarning, [mbYes, mbNo], 0) <> mrYes then Exit;
  end;
  if dlgSaveMod.FileName = '' then
    dlgSaveMod.FileName := 'udaw-export.mod';
  if not dlgSaveMod.Execute then Exit;
  try
    SaveModFile(dlgSaveMod.FileName, FProject.Tracker);
    FTrkPreview := 'exported ' + ExtractFileName(dlgSaveMod.FileName)
      + Format('  (%d issue(s) noted)', [Length(issues)]);
    Logger.Info('ui', 'MOD exported: ' + dlgSaveMod.FileName);
  except
    on E: Exception do
      MessageDlg('MOD export failed:' + sLineBreak + E.Message, mtError, [mbOK], 0);
  end;
  RefreshTrackerTab;
end;

procedure TfrmMain.btnTrkImportXmClick(Sender: TObject);
var
  fs: TFileStream;
  data: TBytes;
  info: TXmImportInfo;
begin
  if not dlgOpenXm.Execute then Exit;
  if not FileLooksLikeXm(dlgOpenXm.FileName) then
  begin
    MessageDlg('That file is not a recognisable FastTracker 2 Extended Module:'
      + sLineBreak + dlgOpenXm.FileName, mtWarning, [mbOK], 0);
    Exit;
  end;
  try
    fs := TFileStream.Create(dlgOpenXm.FileName, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(data, fs.Size);
      if Length(data) > 0 then fs.ReadBuffer(data[0], Length(data));
    finally
      fs.Free;
    end;
    XmToModule(data, info).Free;   { parse once for the report }
    FCmds.Perform(TImportXmCommand.Create(FProject, data,
      ExtractFileName(dlgOpenXm.FileName)));
    FTrkPreview := 'imported ' + ExtractFileName(dlgOpenXm.FileName) + sLineBreak
      + info.Summary;
    Logger.Info('ui', 'XM imported: ' + dlgOpenXm.FileName);
  except
    on E: Exception do
      MessageDlg('XM import failed:' + sLineBreak + E.Message, mtError, [mbOK], 0);
  end;
  FTrkSelRow := 0;
  FTrkSelChn := 0;
  FTrkGridRowScroll := -1;
  FTrkGridChnScroll := 0;
  RefreshTrackerTab;
end;

procedure TfrmMain.btnTrkExportXmClick(Sender: TObject);
var
  issues: TArray<string>;
  msg: string;
  i: Integer;
begin
  if not RequireRegistration('Exporting a .xm') then Exit;
  issues := XmExportIssues(FProject.Tracker);
  if Length(issues) > 0 then
  begin
    msg := 'This project''s tracker module cannot be fully represented in XM:'
      + sLineBreak + sLineBreak;
    for i := 0 to High(issues) do
      msg := msg + '  - ' + issues[i] + sLineBreak;
    msg := msg + sLineBreak + 'Export anyway (best effort)?';
    if MessageDlg(msg, mtWarning, [mbYes, mbNo], 0) <> mrYes then Exit;
  end;
  if dlgSaveXm.FileName = '' then
    dlgSaveXm.FileName := 'udaw-export.xm';
  if not dlgSaveXm.Execute then Exit;
  try
    SaveXmFile(dlgSaveXm.FileName, FProject.Tracker);
    FTrkPreview := 'exported ' + ExtractFileName(dlgSaveXm.FileName)
      + Format('  (%d issue(s) noted)', [Length(issues)]);
    Logger.Info('ui', 'XM exported: ' + dlgSaveXm.FileName);
  except
    on E: Exception do
      MessageDlg('XM export failed:' + sLineBreak + E.Message, mtError, [mbOK], 0);
  end;
  RefreshTrackerTab;
end;

procedure TfrmMain.btnTrkImportMptmClick(Sender: TObject);
var
  fs: TFileStream;
  data: TBytes;
  info: TMPTMImportInfo;
begin
  if not dlgOpenMptm.Execute then Exit;
  if not FileLooksLikeMptm(dlgOpenMptm.FileName) then
  begin
    MessageDlg('That file is not a recognisable IMPM (IT / MPTM) module:'
      + sLineBreak + dlgOpenMptm.FileName, mtWarning, [mbOK], 0);
    Exit;
  end;
  try
    fs := TFileStream.Create(dlgOpenMptm.FileName, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(data, fs.Size);
      if Length(data) > 0 then fs.ReadBuffer(data[0], Length(data));
    finally
      fs.Free;
    end;
    MptmToModule(data, info).Free;   { parse once for the report }
    FCmds.Perform(TImportMptmCommand.Create(FProject, data,
      ExtractFileName(dlgOpenMptm.FileName)));
    FTrkPreview := 'imported ' + ExtractFileName(dlgOpenMptm.FileName) + sLineBreak
      + info.Summary;
    Logger.Info('ui', 'MPTM imported: ' + dlgOpenMptm.FileName);
  except
    on E: Exception do
      MessageDlg('MPTM import failed:' + sLineBreak + E.Message, mtError, [mbOK], 0);
  end;
  FTrkSelRow := 0;
  FTrkSelChn := 0;
  FTrkGridRowScroll := -1;
  FTrkGridChnScroll := 0;
  RefreshTrackerTab;
end;

procedure TfrmMain.btnTrkExportMptmClick(Sender: TObject);
var
  issues: TArray<string>;
  msg: string;
  i: Integer;
begin
  if not RequireRegistration('Exporting a .mptm') then Exit;
  issues := MptmExportIssues(FProject.Tracker);
  if Length(issues) > 0 then
  begin
    msg := 'MPTM export notes for this project''s tracker module:'
      + sLineBreak + sLineBreak;
    for i := 0 to High(issues) do
      msg := msg + '  - ' + issues[i] + sLineBreak;
    msg := msg + sLineBreak + 'Export anyway (best effort)?';
    if MessageDlg(msg, mtWarning, [mbYes, mbNo], 0) <> mrYes then Exit;
  end;
  if dlgSaveMptm.FileName = '' then
    dlgSaveMptm.FileName := 'udaw-export.mptm';
  if not dlgSaveMptm.Execute then Exit;
  try
    SaveMptmFile(dlgSaveMptm.FileName, FProject.Tracker);
    FTrkPreview := 'exported ' + ExtractFileName(dlgSaveMptm.FileName)
      + Format('  (%d note(s))', [Length(issues)]);
    Logger.Info('ui', 'MPTM exported: ' + dlgSaveMptm.FileName);
  except
    on E: Exception do
      MessageDlg('MPTM export failed:' + sLineBreak + E.Message, mtError, [mbOK], 0);
  end;
  RefreshTrackerTab;
end;

procedure TfrmMain.pbTrackerMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
const
  ROWH = 16;
  COLW = 96;
  HDR = 20;
  GUT = 40;
var
  pat: TTrackerPattern;
begin
  pat := FProject.Tracker.GetPattern(SelectedTrackerPattern);
  if pat = nil then Exit;
  if (Y < HDR) or (X < GUT) then Exit;
  FTrkSelRow := (Y - HDR) div ROWH + FTrkGridLastFirstRow;
  FTrkSelChn := (X - GUT) div COLW + FTrkGridChnScroll;
  if FTrkSelRow >= pat.Rows then FTrkSelRow := pat.Rows - 1;
  if FTrkSelChn >= pat.Channels then FTrkSelChn := pat.Channels - 1;
  RefreshTrackerTab;
end;

{ Mouse wheel over the pattern grid scrolls the row view manually (each
  notch = 3 rows), overriding auto-follow-selection/playback until the user
  switches pattern or picks a fresh cell - see FTrkGridRowScroll. Shift+wheel
  scrolls the channel columns instead, mirroring pbTimelineMouseWheel's
  Shift-for-horizontal convention. }
procedure TfrmMain.pbTrackerMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
const
  ROWH = 16;
  HDR = 20;
  ROWS_PER_NOTCH = 3;
var
  pat: TTrackerPattern;
  visRows, maxFirstRow: Integer;
begin
  if FProject = nil then Exit;
  pat := FProject.Tracker.GetPattern(SelectedTrackerPattern);
  if pat = nil then Exit;
  if ssShift in Shift then
  begin
    if WheelDelta > 0 then
      FTrkGridChnScroll := Max(0, FTrkGridChnScroll - 1)
    else if WheelDelta < 0 then
      FTrkGridChnScroll := Min(sbTrkChn.Max, FTrkGridChnScroll + 1);
    RefreshTrackerTab;
    Handled := True;
    Exit;
  end;
  visRows := Max(1, (pbTracker.Height - HDR) div ROWH);
  maxFirstRow := Max(0, pat.Rows - visRows);
  if FTrkGridRowScroll < 0 then
    FTrkGridRowScroll := EnsureRange(FTrkSelRow - visRows div 2, 0, maxFirstRow);
  if WheelDelta > 0 then
    FTrkGridRowScroll := Max(0, FTrkGridRowScroll - ROWS_PER_NOTCH)
  else if WheelDelta < 0 then
    FTrkGridRowScroll := Min(maxFirstRow, FTrkGridRowScroll + ROWS_PER_NOTCH);
  pbTracker.Invalidate;
  Handled := True;
end;

procedure TfrmMain.sbTrkChnChange(Sender: TObject);
begin
  if FTrkRefreshing then Exit;
  FTrkGridChnScroll := sbTrkChn.Position;
  pbTracker.Invalidate;
end;

{ ---- Instruments sub-tab: pick a tracker instrument, see its sample
       waveform, and either bounce it to the Timeline as a real audio clip
       or save it out as a standalone .wav. ---- }

procedure TfrmMain.RefreshTrkInstrTab;
var
  m: TTrackerModule;
  i: Integer;
begin
  if FProject = nil then Exit;
  m := FProject.Tracker;
  cboTrkInstrSel.Items.BeginUpdate;
  try
    cboTrkInstrSel.Items.Clear;
    for i := 1 to m.InstrumentCount do
      cboTrkInstrSel.Items.Add(Format('%2d  %s', [i, m.GetInstrument(i).Name]));
  finally
    cboTrkInstrSel.Items.EndUpdate;
  end;
  if FTrkInstrIndex > m.InstrumentCount then FTrkInstrIndex := m.InstrumentCount;
  if (FTrkInstrIndex < 1) and (m.InstrumentCount > 0) then FTrkInstrIndex := 1;
  cboTrkInstrSel.ItemIndex := FTrkInstrIndex - 1;
  cboTrkInstrSelChange(nil);
end;

procedure TfrmMain.cboTrkInstrSelChange(Sender: TObject);
var
  instr: TTrackerInstrument;
begin
  FTrkInstrIndex := cboTrkInstrSel.ItemIndex + 1;
  if FProject = nil then Exit;
  instr := FProject.Tracker.GetInstrument(FTrkInstrIndex);
  if instr = nil then
    lblTrkInstrInfo.Caption := '(no instrument selected)'
  else
    lblTrkInstrInfo.Caption := instr.Describe;
  btnTrkInstrAddTimeline.Enabled := (instr <> nil) and (instr.FrameCount > 0);
  btnTrkInstrSaveWav.Enabled := btnTrkInstrAddTimeline.Enabled;
  pbTrkInstrWave.Invalidate;
end;

{ Writes the samples as headerless little-endian PCM in AFmt (8-bit is
  unsigned, as in WAV). }
procedure WriteRawPcmFile(const AFileName: string; const AData: TAudioSampleArray;
  AFrames: Integer; AFmt: TWavSampleFormat);
var
  fs: TFileStream;
  buf: TBytes;
  i, n, o: Integer;
  v: Double;
  i32: Integer;
  f32: Single;
  f64: Double;
begin
  n := WavSampleFormatBytes(AFmt);
  SetLength(buf, AFrames * n);
  for i := 0 to AFrames - 1 do
  begin
    v := AData[i];
    if v > 1 then v := 1 else if v < -1 then v := -1;
    o := i * n;
    case AFmt of
      wsfPCM8:  buf[o] := Byte(Round(v * 127) + 128);
      wsfPCM16: begin i32 := Round(v * 32767); buf[o] := i32 and $FF; buf[o + 1] := (i32 shr 8) and $FF; end;
      wsfPCM24: begin i32 := Round(v * 8388607); buf[o] := i32 and $FF; buf[o + 1] := (i32 shr 8) and $FF; buf[o + 2] := (i32 shr 16) and $FF; end;
      wsfPCM32: begin i32 := Round(v * 2147483647.0); Move(i32, buf[o], 4); end;
      wsfFloat32: begin f32 := v; Move(f32, buf[o], 4); end;
    else
      f64 := v; Move(f64, buf[o], 8);
    end;
  end;
  fs := TFileStream.Create(AFileName, fmCreate);
  try
    if Length(buf) > 0 then fs.WriteBuffer(buf[0], Length(buf));
  finally
    fs.Free;
  end;
end;

{ Text description of everything applied to a tracker instrument (loop,
  volume/pan, fadeout, envelopes) - embedded in the WAV and written as a
  sidecar for PCM/FLAC so the settings travel with the exported sample. }
function InstrumentSettingsText(AInstr: TTrackerInstrument): string;

  function EnvText(const AEnv: TTrackerEnvelope): string;
  var
    i: Integer;
  begin
    if (not AEnv.Enabled) or (Length(AEnv.Points) = 0) then Exit('off');
    Result := 'on';
    for i := 0 to High(AEnv.Points) do
      Result := Result + Format(' %d:%.3f', [AEnv.Points[i].Tick, AEnv.Points[i].Value],
        TFormatSettings.Invariant);
    Result := Result + Format(' sustain=%d loop=%d-%d',
      [AEnv.SustainPoint, AEnv.LoopStart, AEnv.LoopEnd]);
  end;

begin
  Result := Format('UDAW tracker instrument; name=%s; root=%s; rate=%d; frames=%d; ' +
    'loop=%s; loopstart=%d; loopend=%d; volume=%.3f; pan=%.3f; ' +
    'fadeout=%.4f (fraction removed per tick after key-off); volenv=%s; panenv=%s',
    [AInstr.Name, NoteName(AInstr.RootNote), AInstr.SampleRate, AInstr.FrameCount,
     LoopModeId(AInstr.LoopMode), AInstr.LoopStart, AInstr.LoopEnd,
     AInstr.Volume, AInstr.Pan, AInstr.Fadeout,
     EnvText(AInstr.VolEnv), EnvText(AInstr.PanEnv)], TFormatSettings.Invariant);
end;

{ Appends a "smpl" chunk (root note + loop points, read by samplers/editors)
  and a LIST/INFO chunk (name + the full settings text) to a finished
  RIFF/WAVE file, then fixes up the RIFF size. }
procedure AppendWavInstrumentChunks(const AFileName: string; AInstr: TTrackerInstrument);
var
  fs: TFileStream;
  tag: array[0..3] of AnsiChar;
  sz: Cardinal;

  procedure U32(V: Cardinal);
  begin
    fs.WriteBuffer(V, 4);
  end;

  procedure Tag4(const T: AnsiString);
  begin
    fs.WriteBuffer(T[1], 4);
  end;

  function Z(const S: string): TBytes;
  begin
    Result := TEncoding.UTF8.GetBytes(S + #0);
  end;

  function PaddedLen(const B: TBytes): Cardinal;
  begin
    Result := Length(B) + (Length(B) and 1);
  end;

  procedure InfoItem(const T: AnsiString; const B: TBytes);
  var
    pad: Byte;
  begin
    Tag4(T);
    U32(Length(B));
    fs.WriteBuffer(B[0], Length(B));
    if (Length(B) and 1) <> 0 then begin pad := 0; fs.WriteBuffer(pad, 1); end;
  end;

var
  looped: Boolean;
  loopEnd, root: Integer;
  nameB, cmtB, sftB: TBytes;
  listSize: Cardinal;
begin
  fs := TFileStream.Create(AFileName, fmOpenReadWrite);
  try
    if fs.Size < 12 then Exit;
    fs.ReadBuffer(tag, 4);
    if tag <> 'RIFF' then Exit;   // RF64 / anything else: leave untouched
    fs.Seek(0, soEnd);

    looped := AInstr.LoopMode <> tlmOff;
    loopEnd := AInstr.LoopEnd - 1;                 // smpl end is inclusive
    if loopEnd < AInstr.LoopStart then loopEnd := AInstr.LoopStart;
    root := AInstr.RootNote;
    if root > 127 then root := 127;

    Tag4('smpl');
    if looped then U32(36 + 24) else U32(36);
    U32(0); U32(0);                                // manufacturer, product
    U32(Round(1.0e9 / Max(1, AInstr.SampleRate))); // sample period (ns)
    U32(root); U32(0); U32(0); U32(0);             // unity note, fraction, SMPTE fmt/offset
    if looped then U32(1) else U32(0);             // loop count
    U32(0);                                        // sampler data
    if looped then
    begin
      U32(0);                                      // cue id
      if AInstr.LoopMode = tlmPingPong then U32(1) else U32(0);
      U32(AInstr.LoopStart); U32(loopEnd);
      U32(0); U32(0);                              // fraction, play count (0 = infinite)
    end;

    nameB := Z(AInstr.Name);
    cmtB := Z(InstrumentSettingsText(AInstr));
    sftB := Z('UDAW');
    listSize := 4 + 8 + PaddedLen(nameB) + 8 + PaddedLen(cmtB) + 8 + PaddedLen(sftB);
    Tag4('LIST');
    U32(listSize);
    Tag4('INFO');
    InfoItem('INAM', nameB);
    InfoItem('ICMT', cmtB);
    InfoItem('ISFT', sftB);

    sz := Cardinal(fs.Size - 8);
    fs.Seek(4, soBeginning);
    fs.WriteBuffer(sz, 4);
  finally
    fs.Free;
  end;
end;

{ Exports the selected tracker instrument's sample for use elsewhere:
  WAV / raw PCM / FLAC. Bit depth comes from the "Write format" box on the
  Supported SFX (WAV) tab; FLAC is integer-only so a float choice becomes
  24-bit there. WAV gets smpl (loop/root note) + LIST/INFO (all applied
  settings) chunks; PCM/FLAC get a <file>.txt sidecar with the same text. }
procedure TfrmMain.btnTrkInstrSaveWavClick(Sender: TObject);
var
  instr: TTrackerInstrument;
  planar: TAudioPlanar;
  fmt: TWavSampleFormat;
  fn, tmp, kind: string;
  oldFilter: string;
  sl: TStringList;
begin
  if not RequireRegistration('Exporting a sample') then Exit;
  if FProject = nil then Exit;
  instr := FProject.Tracker.GetInstrument(FTrkInstrIndex);
  if (instr = nil) or (instr.FrameCount = 0) then Exit;
  oldFilter := dlgSaveWav.Filter;
  dlgSaveWav.Filter := 'WAV audio (*.wav)|*.wav|Raw PCM (*.pcm)|*.pcm|FLAC lossless (*.flac)|*.flac';
  dlgSaveWav.FilterIndex := 1;
  dlgSaveWav.FileName := SafeSunoFileName(instr.Name);
  try
    if not dlgSaveWav.Execute then Exit;
    fn := dlgSaveWav.FileName;
    case dlgSaveWav.FilterIndex of
      2: begin kind := 'PCM';  fn := ChangeFileExt(fn, '.pcm'); end;
      3: begin kind := 'FLAC'; fn := ChangeFileExt(fn, '.flac'); end;
    else
      kind := 'WAV'; fn := ChangeFileExt(fn, '.wav');
    end;
  finally
    dlgSaveWav.Filter := oldFilter;
  end;
  fmt := SelectedWavFormat;
  SetLength(planar, 1);
  planar[0] := Copy(instr.Data);
  ShowStatusProgress('Exporting ' + ExtractFileName(fn) + '...', 100);
  try
    try
      if kind = 'PCM' then
        WriteRawPcmFile(fn, planar[0], instr.FrameCount, fmt)
      else if kind = 'FLAC' then
      begin
        if fmt in [wsfPCM32, wsfFloat32, wsfFloat64] then fmt := wsfPCM24;
        tmp := ChangeFileExt(fn, '.tmp.wav');
        try
          SaveWavFile(tmp, planar, 1, instr.SampleRate, instr.FrameCount, fmt);
          UpdateStatusProgress(40, 'Encoding FLAC...');
          FlacEncodeToFile(tmp, fn);
        finally
          if FileExists(tmp) then DeleteFile(tmp);
        end;
      end
      else
      begin
        SaveWavFile(fn, planar, 1, instr.SampleRate, instr.FrameCount, fmt);
        AppendWavInstrumentChunks(fn, instr);   // loop points + applied settings
      end;
      if kind <> 'WAV' then
      begin
        sl := TStringList.Create;
        try
          sl.Text := StringReplace(InstrumentSettingsText(instr), '; ', sLineBreak, [rfReplaceAll]);
          sl.SaveToFile(fn + '.txt', TEncoding.UTF8);
        finally
          sl.Free;
        end;
      end;
      lblTrkInstrInfo.Caption := 'saved ' + ExtractFileName(fn) + ' (' + kind + ', ' +
        WavSampleFormatName(fmt) + ', ' + IntToStr(instr.SampleRate) + ' Hz)  --  ' + instr.Describe;
      Logger.Info('ui', 'Tracker instrument exported (' + kind + '): ' + fn);
    except
      on E: Exception do
        MessageDlg('Export failed:' + sLineBreak + E.Message, mtError, [mbOK], 0);
    end;
  finally
    HideStatusProgress;
  end;
end;

{ Bounces the instrument's sample to a real .wav file in the Recordings
  folder (not Cache - see RecordingRootPath) and imports that file onto the
  Timeline via the same path as a dropped/browsed audio file, so the
  resulting clip is backed by durable media like any other import. }
procedure TfrmMain.btnTrkInstrAddTimelineClick(Sender: TObject);
var
  instr: TTrackerInstrument;
  planar: TAudioPlanar;
  dir, fileName: string;
  trackId: Integer;
begin
  if FProject = nil then Exit;
  instr := FProject.Tracker.GetInstrument(FTrkInstrIndex);
  if (instr = nil) or (instr.FrameCount = 0) then Exit;
  try
    dir := IncludeTrailingPathDelimiter(RecordingRootPath);
    ForceDirectories(dir);
    fileName := dir + Format('instrument-%.2d-%s-%s.wav',
      [FTrkInstrIndex, SafeSunoFileName(instr.Name), FormatDateTime('yyyymmdd-hhnnsszzz', Now)]);
    SetLength(planar, 1);
    planar[0] := Copy(instr.Data);
    SaveWavFile(fileName, planar, 1, instr.SampleRate, instr.FrameCount, wsfPCM16);
    trackId := TlSelectedAudioTrackId;
    if trackId < 0 then trackId := TlNewAudioTrackId;
    if ImportBrowserFileToTimeline(fileName, trackId, FTlView.Snap(FProject.Timeline.PlayheadSeconds)) then
    begin
      lblTrkInstrInfo.Caption := 'added to Timeline: ' + ExtractFileName(fileName);
      Logger.Info('ui', 'Tracker instrument added to timeline: ' + fileName);
    end
    else
      MessageDlg('Could not add the instrument to the Timeline.', mtError, [mbOK], 0);
  except
    on E: Exception do
      MessageDlg('Add to Timeline failed:' + sLineBreak + E.Message, mtError, [mbOK], 0);
  end;
end;

{ Simple min/max-per-column waveform, double-buffered like pbTrackerPaint to
  avoid the flicker the Recording/Audio/DSP tabs had before they got the
  same treatment. }
procedure TfrmMain.pbTrkInstrWavePaint(Sender: TObject);
const
  MARGIN = 8;
var
  cv: TCanvas;
  w, h, midY, i, x0, x1, px: Integer;
  instr: TTrackerInstrument;
  lo, hi, v: Single;
  framesPerPx: Double;
begin
  if FTrkInstrWaveBuffer = nil then Exit;
  w := pbTrkInstrWave.Width;
  h := pbTrkInstrWave.Height;
  if (w <= 0) or (h <= 0) then Exit;
  FTrkInstrWaveBuffer.SetSize(w, h);
  cv := FTrkInstrWaveBuffer.Canvas;
  cv.Brush.Style := bsSolid;
  cv.Brush.Color := $00181818;
  cv.FillRect(Rect(0, 0, w, h));
  instr := nil;
  if FProject <> nil then instr := FProject.Tracker.GetInstrument(FTrkInstrIndex);
  midY := h div 2;
  cv.Pen.Color := $00404040;
  cv.MoveTo(0, midY);
  cv.LineTo(w, midY);
  if (instr = nil) or (instr.FrameCount = 0) then
  begin
    cv.Font.Color := $00808080;
    cv.Brush.Style := bsClear;
    cv.TextOut(MARGIN, MARGIN, '(no sample data)');
  end
  else
  begin
    framesPerPx := instr.FrameCount / Max(1, w - 2 * MARGIN);
    cv.Pen.Color := $0060C0A0;
    for px := 0 to (w - 2 * MARGIN) - 1 do
    begin
      x0 := Trunc(px * framesPerPx);
      x1 := Trunc((px + 1) * framesPerPx);
      if x1 <= x0 then x1 := x0 + 1;
      if x1 > instr.FrameCount then x1 := instr.FrameCount;
      if x0 >= x1 then Continue;
      lo := 1.0; hi := -1.0;
      for i := x0 to x1 - 1 do
      begin
        v := instr.Data[i];
        if v < lo then lo := v;
        if v > hi then hi := v;
      end;
      cv.MoveTo(MARGIN + px, midY - Round(hi * (h div 2 - MARGIN)));
      cv.LineTo(MARGIN + px, midY - Round(lo * (h div 2 - MARGIN)));
    end;
  end;
  pbTrkInstrWave.Canvas.Draw(0, 0, FTrkInstrWaveBuffer);
end;

procedure TfrmMain.pbTrackerPaint(Sender: TObject);
const
  ROWH = 16;
  COLW = 96;
  HDR = 20;
  GUT = 40;
var
  cv: TCanvas;
  w, h, r, c, y, x, firstRow, visRows, firstChn, lastChn: Integer;
  pat: TTrackerPattern;
  cell: TTrackerCell;
  txt: string;
  playingHere: Boolean;
  playRow: Integer;
begin
  if FTrkPatternBuffer = nil then Exit;
  w := pbTracker.Width;
  h := pbTracker.Height;
  if (w <= 0) or (h <= 0) then Exit;
  FTrkPatternBuffer.SetSize(w, h);
  cv := FTrkPatternBuffer.Canvas;
  try
  cv.Brush.Style := bsSolid;
  cv.Brush.Color := $00181818;
  cv.FillRect(Rect(0, 0, w, h));
  if FProject = nil then Exit;
  pat := FProject.Tracker.GetPattern(SelectedTrackerPattern);
  if pat = nil then Exit;

  playingHere := FTrkPlaying and (FTrkPlayer <> nil) and
    (FTrkPlayer.CurrentPatternIndex = SelectedTrackerPattern);
  playRow := -1;
  if playingHere then playRow := FTrkPlayer.CurrentRow;

  cv.Font.Name := 'Consolas';
  cv.Font.Size := 9;

  visRows := (h - HDR) div ROWH;
  { manual mouse-wheel scroll (FTrkGridRowScroll >= 0) sticks until the user
    switches pattern or clicks a cell; playback always overrides it so the
    moving playhead stays visible; otherwise fall back to centering on the
    selected row. }
  if playingHere then
    firstRow := playRow - visRows div 2
  else if FTrkGridRowScroll >= 0 then
    firstRow := FTrkGridRowScroll
  else
    firstRow := FTrkSelRow - visRows div 2;
  if firstRow < 0 then firstRow := 0;
  if firstRow + visRows > pat.Rows then firstRow := Max(0, pat.Rows - visRows);
  FTrkGridLastFirstRow := firstRow;

  firstChn := Min(FTrkGridChnScroll, Max(0, pat.Channels - 1));
  lastChn := Min(pat.Channels - 1, firstChn + (w - GUT) div COLW);

  cv.Brush.Style := bsClear;
  cv.Font.Color := $00909090;
  for c := firstChn to lastChn do
    cv.TextOut(GUT + (c - firstChn) * COLW, 2, Format('Ch %d', [c + 1]));

  for r := firstRow to Min(pat.Rows - 1, firstRow + visRows) do
  begin
    y := HDR + (r - firstRow) * ROWH;
    if (r mod 4) = 0 then
    begin
      cv.Brush.Style := bsSolid;
      cv.Brush.Color := $00222228;
      cv.FillRect(Rect(0, y, w, y + ROWH));
      cv.Brush.Style := bsClear;
    end;
    cv.Font.Color := $00707070;
    cv.TextOut(4, y, IntToHex(r, 2));

    if r = playRow then
    begin
      cv.Brush.Style := bsSolid;
      cv.Brush.Color := $00204020;
      cv.FillRect(Rect(0, y, w, y + ROWH));
      cv.Brush.Style := bsClear;
    end;

    for c := firstChn to lastChn do
    begin
      x := GUT + (c - firstChn) * COLW;
      if (r = FTrkSelRow) and (c = FTrkSelChn) then
      begin
        cv.Brush.Style := bsSolid;
        cv.Brush.Color := $00404830;
        cv.FillRect(Rect(x - 2, y, x + COLW - 4, y + ROWH));
        cv.Brush.Style := bsClear;
      end;
      cell := pat.GetCell(r, c);
      if cell.IsEmpty then
        txt := '... .. .. ...'
      else
      begin
        txt := NoteName(cell.Note) + ' ';
        if cell.Instrument = TRK_INSTR_NONE then txt := txt + '.. '
        else txt := txt + IntToHex(cell.Instrument, 2) + ' ';
        if cell.Volume > TRK_VOL_MAX then txt := txt + '.. '
        else txt := txt + IntToHex(cell.Volume, 2) + ' ';
        if (cell.Effect = tfxNone) and (cell.Param = 0) then txt := txt + '...'
        else txt := txt + EffectLetter(cell.Effect) + IntToHex(cell.Param, 2);
      end;
      if cell.IsEmpty then cv.Font.Color := $00505050 else cv.Font.Color := $00D8D8D8;
      cv.TextOut(x, y, txt);
    end;
  end;
  finally
    pbTracker.Canvas.Draw(0, 0, FTrkPatternBuffer);
  end;
end;

{ ---- Sequence strip: one cell per order step ("step N -> pattern P"),
       always following playback (auto-scrolls + highlights the playing
       step) so "where it's up to" is visible without hunting through the
       order list. Click a step to act on it - see the handler for the
       stopped-vs-playing behaviour the request specifically calls for. }

function TfrmMain.TrkSeqStepWidth: Integer;
begin
  Result := 64;
end;

procedure TfrmMain.pbTrkSequencePaint(Sender: TObject);
const
  STEPH = 24;
var
  cv: TCanvas;
  w, h, i, x, stepW, visCount: Integer;
  m: TTrackerModule;
  patIdx: Integer;
  isPlayingStep, isShownPattern: Boolean;
begin
  if FTrkSequenceBuffer = nil then Exit;
  w := pbTrkSequence.Width;
  h := pbTrkSequence.Height;
  if (w <= 0) or (h <= 0) then Exit;
  FTrkSequenceBuffer.SetSize(w, h);
  cv := FTrkSequenceBuffer.Canvas;
  try
  cv.Brush.Style := bsSolid;
  cv.Brush.Color := $00181818;
  cv.FillRect(Rect(0, 0, w, h));
  if FProject = nil then Exit;
  m := FProject.Tracker;
  if m.OrderLength = 0 then Exit;

  stepW := TrkSeqStepWidth;
  cv.Font.Name := 'Consolas';
  cv.Font.Size := 8;
  visCount := (w div stepW) + 2;

  for i := FTrkSeqScroll to Min(m.OrderLength - 1, FTrkSeqScroll + visCount) do
  begin
    x := (i - FTrkSeqScroll) * stepW;
    patIdx := m.GetOrder(i);
    isPlayingStep := FTrkPlaying and (FTrkPlayer <> nil) and (FTrkPlayer.CurrentOrder = i);
    isShownPattern := (not FTrkPlaying) and (patIdx = SelectedTrackerPattern);

    cv.Brush.Style := bsSolid;
    if isPlayingStep then cv.Brush.Color := $0040C040
    else if isShownPattern then cv.Brush.Color := $00405858
    else if (i mod 2) = 0 then cv.Brush.Color := $00222228
    else cv.Brush.Color := $001C1C20;
    cv.FillRect(Rect(x, 0, x + stepW - 2, h));
    cv.Brush.Style := bsClear;

    if isPlayingStep then cv.Font.Color := $00102010 else cv.Font.Color := $00C0C0C0;
    cv.TextOut(x + 4, 1, Format('%.2d', [i]));
    cv.TextOut(x + 4, 12, Format('pat %d', [patIdx]));
  end;
  finally
    pbTrkSequence.Canvas.Draw(0, 0, FTrkSequenceBuffer);
  end;
end;

procedure TfrmMain.pbTrkSequenceMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  m: TTrackerModule;
  step, patIdx: Integer;
begin
  if FProject = nil then Exit;
  m := FProject.Tracker;
  if m.OrderLength = 0 then Exit;

  step := FTrkSeqScroll + (X div TrkSeqStepWidth);
  if (step < 0) or (step >= m.OrderLength) then Exit;
  patIdx := m.GetOrder(step);

  if FTrkPlaying and (FTrkPlayer <> nil) then
    { playing: relocate the transport to row 0 of this step and keep going }
    FTrkPlayer.JumpToOrder(step)
  else
  begin
    { stopped: just bring that step's pattern into the editor }
    if (patIdx >= 0) and (patIdx < cboTrkPattern.Items.Count) then
      cboTrkPattern.ItemIndex := patIdx;
    FTrkSelRow := 0;
  end;
  RefreshTrackerTab;
end;

procedure TfrmMain.sbTrkSeqChange(Sender: TObject);
begin
  FTrkSeqScroll := sbTrkSeq.Position;
  pbTrkSequence.Invalidate;
end;

procedure TfrmMain.btnRefreshSystemClick(Sender: TObject);
begin
  RefreshSystemTab;
end;

procedure TfrmMain.btnTrkSupportClick(Sender: TObject);
begin
  OpenInShell('https://www.modplug.com/');
end;

procedure TfrmMain.OpenInShell(const APath: string);
begin
  {$IFDEF FPC}
  OpenDocument(APath);
  {$ELSE}
  ShellExecute(0, 'open', PChar(APath), nil, nil, SW_SHOWNORMAL);
  {$ENDIF}
end;

{ Fetches the client-only UDAW Help Centre page from our web server (it is
  gated on the exact Referer: UDAW/1.0 header - see UDAW_HELP_URL), saves it
  to a local temp file, and opens that file in a dedicated window of its own
  (UDAW.UI.HelpForm's embedded TWebBrowser) so the user can read it without
  leaving UDAW.

  Windows/Delphi build: the fetch goes through UDAW.Web.HelpClient - Indy's
  TIdHTTP with a TaurusTLS (OpenSSL) IOHandler - rather than
  System.Net.HttpClient. FPC build: no embedded browser control is available
  under LCL and that leg has no TaurusTLS wired in, so it keeps using the
  cross-platform TAIHttpClient and opens the saved file in the OS default
  browser instead. }
procedure TfrmMain.btnHelpAboutClick(Sender: TObject);
{$IFDEF FPC}
var
  http: TAIHttpClient;
  resp: TAIHttpResponse;
  header: TAIHttpHeader;
  helpFile: string;
  html: TStringList;
begin
  http := TAIHttpClient.Create;
  try
    header.Name := 'Referer';
    header.Value := UDAW_HELP_REFERER;
    try
      resp := http.Get(UDAW_HELP_URL, [header]);
    except
      on E: Exception do
      begin
        MessageDlg('Could not reach the UDAW Help Centre:' + sLineBreak + E.Message,
          mtError, [mbOK], 0);
        Exit;
      end;
    end;
  finally
    http.Free;
  end;

  if resp.StatusCode <> 200 then
  begin
    MessageDlg(Format('UDAW Help Centre returned HTTP %d.', [resp.StatusCode]),
      mtError, [mbOK], 0);
    Exit;
  end;

  if App = nil then Exit;
  helpFile := IncludeTrailingPathDelimiter(App.Paths.Temp) + 'udaw-help.html';
  html := TStringList.Create;
  try
    html.WriteBOM := False;
    html.Text := resp.Body;
    html.SaveToFile(helpFile, TEncoding.UTF8);
  finally
    html.Free;
  end;

  OpenInShell(helpFile);
end;
{$ELSE}
var
  htmlText, errMsg, localHelp: string;
  localText: TStringList;
begin
  localHelp := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'WebCache' + PathDelim + 'udaw-help.html';
  if FileExists(localHelp) then
  begin
    localText := TStringList.Create;
    try
      localText.LoadFromFile(localHelp, TEncoding.UTF8);
      htmlText := localText.Text;
    finally
      localText.Free;
    end;
  end
  else if not FetchUDAWHelpPage(htmlText, errMsg) then
  begin
    MessageDlg('Could not reach the UDAW Help Centre:' + sLineBreak + errMsg,
      mtError, [mbOK], 0);
    Exit;
  end;

  try
    with TfrmHelp.Create(Application) do
    begin
      ShowHtml(htmlText);
      Show;
    end;
  except
    on E: Exception do
      MessageDlg('Could not open the UDAW Help Centre window:' + sLineBreak + E.Message,
        mtError, [mbOK], 0);
  end;
end;
{$ENDIF}

procedure TfrmMain.btnAboutClick(Sender: TObject);
begin
  ShowAboutDialog;
end;

procedure TfrmMain.btnOpenConfigDirClick(Sender: TObject);
begin
  if App <> nil then
    OpenInShell(App.Paths.Config);
end;

procedure TfrmMain.btnOpenLogDirClick(Sender: TObject);
begin
  if App <> nil then
    OpenInShell(App.Paths.Logs);
end;

procedure TfrmMain.btnApplyLevelClick(Sender: TObject);
begin
  if (App <> nil) and (cboLevel.ItemIndex >= 0) then
  begin
    Logger.SetMinLevel(App.ParseLogLevel(cboLevel.Text, llInfo));
    App.Config.SetString('logging', 'level', cboLevel.Text);
    App.Config.Save;
    Logger.Info('ui', 'log level set to ' + cboLevel.Text);
  end;
end;

procedure TfrmMain.btnEmitInfoClick(Sender: TObject);
begin
  Logger.Info('ui', 'manual INFO test entry');
end;

procedure TfrmMain.btnEmitWarnClick(Sender: TObject);
begin
  Logger.Warn('ui', 'manual WARN test entry');
end;

procedure TfrmMain.btnEmitErrorClick(Sender: TObject);
begin
  Logger.Error('ui', 'manual ERROR test entry');
end;

procedure TfrmMain.btnClearLogViewClick(Sender: TObject);
begin
  lvLog.Items.Clear;
  FLogShown := 0;
  if App <> nil then
    App.MemoryLog.Clear;
end;

procedure TfrmMain.btnRunSelfTestClick(Sender: TObject);
var
  job: TSelfTestJob;
begin
  if App = nil then Exit;
  job := TSelfTestJob.Create('Self-test');
  FTrackedJobs.Add(job);
  App.Jobs.Submit(job, False);
  Logger.Info('ui', 'self-test job submitted');
  RefreshJobs;
end;

procedure TfrmMain.btnCancelJobsClick(Sender: TObject);
begin
  if App <> nil then
    App.Jobs.CancelAll;
end;

procedure TfrmMain.btnSecretSetClick(Sender: TObject);
begin
  if (App = nil) or (App.Secure = nil) then Exit;
  try
    App.Secure.SetSecret(Trim(edtKey.Text), edtValue.Text);
    memSecure.Lines.Add('SET  ' + edtKey.Text + '  ->  stored');
  except
    on E: Exception do
      memSecure.Lines.Add('SET  failed: ' + E.Message);
  end;
end;

procedure TfrmMain.btnSecretGetClick(Sender: TObject);
var
  v: string;
begin
  if (App = nil) or (App.Secure = nil) then Exit;
  try
    if App.Secure.GetSecret(Trim(edtKey.Text), v) then
      begin
        if chkSecReveal.Checked then
          memSecure.Lines.Add('GET  ' + edtKey.Text + '  ->  "' + v + '"')
        else
          memSecure.Lines.Add(Format('GET  %s  ->  %s  (%d chars, masked)',
            [edtKey.Text, StringOfChar('*', Min(Length(v), 12)), Length(v)]));
      end
    else
      memSecure.Lines.Add('GET  ' + edtKey.Text + '  ->  (not found)');
  except
    on E: Exception do
      memSecure.Lines.Add('GET  failed: ' + E.Message);
  end;
end;

procedure TfrmMain.btnSecretDeleteClick(Sender: TObject);
begin
  if (App = nil) or (App.Secure = nil) then Exit;
  try
    App.Secure.DeleteSecret(Trim(edtKey.Text));
    memSecure.Lines.Add('DEL  ' + edtKey.Text + '  ->  removed');
  except
    on E: Exception do
      memSecure.Lines.Add('DEL  failed: ' + E.Message);
  end;
end;

{ Fingerprint of the open project: name, tempo and content counts. }
function TfrmMain.ProjectFingerprint: string;
begin
  if FProject = nil then Exit('');
  Result := Format('%s|%.3f|%d|%d|%d', [FProject.Name, FProject.TempoBPM,
    FProject.Timeline.TrackCount, FProject.Timeline.ClipCountTotal,
    FProject.Tracker.InstrumentCount], TFormatSettings.Invariant);
end;

function TfrmMain.ProjectSecretKey: string;
begin
  Result := 'udaw.project.' + SafeSunoFileName(FProject.Name) + '.fingerprint';
end;

{ Demonstrates the secure store against the real project: the fingerprint
  is DPAPI-encrypted per Windows user, so it cannot be read or forged by
  another account or by editing files on disk. }
procedure TfrmMain.btnSecSealClick(Sender: TObject);
begin
  if (App = nil) or (App.Secure = nil) or (FProject = nil) then
  begin
    memSecure.Lines.Add('SEAL  no project open');
    Exit;
  end;
  try
    App.Secure.SetSecret(ProjectSecretKey, ProjectFingerprint);
    memSecure.Lines.Add(Format('SEAL  "%s"  ->  %d tracks, %d clips, %.2f BPM  encrypted with %s',
      [FProject.Name, FProject.Timeline.TrackCount, FProject.Timeline.ClipCountTotal,
       FProject.TempoBPM, App.Secure.ProviderName]));
  except
    on E: Exception do
      memSecure.Lines.Add('SEAL  failed: ' + E.Message);
  end;
end;

procedure TfrmMain.btnSecVerifyClick(Sender: TObject);
var
  stored: string;
begin
  if (App = nil) or (App.Secure = nil) or (FProject = nil) then
  begin
    memSecure.Lines.Add('VERIFY  no project open');
    Exit;
  end;
  try
    if not App.Secure.GetSecret(ProjectSecretKey, stored) then
      memSecure.Lines.Add('VERIFY  "' + FProject.Name + '"  ->  not sealed yet (use Seal current project)')
    else if stored = ProjectFingerprint then
      memSecure.Lines.Add('VERIFY  "' + FProject.Name + '"  ->  UNCHANGED since sealed')
    else
    begin
      memSecure.Lines.Add('VERIFY  "' + FProject.Name + '"  ->  CHANGED since sealed');
      if chkSecReveal.Checked then
      begin
        memSecure.Lines.Add('         sealed : ' + stored);
        memSecure.Lines.Add('         current: ' + ProjectFingerprint);
      end;
    end;
  except
    on E: Exception do
      memSecure.Lines.Add('VERIFY  failed: ' + E.Message);
  end;
end;

procedure TfrmMain.btnSecProbeClick(Sender: TObject);
const
  K = 'udaw.ui.probe';
  V = 'round-trip-ok';
var
  back: string;
begin
  if (App = nil) or (App.Secure = nil) then Exit;
  try
    App.Secure.SetSecret(K, V);
    if App.Secure.GetSecret(K, back) and (back = V) then
      memSecure.Lines.Add('PROBE  store -> read -> match  OK  (' + App.Secure.ProviderName + ')')
    else
      memSecure.Lines.Add('PROBE  read-back MISMATCH');
    App.Secure.DeleteSecret(K);
  except
    on E: Exception do
      memSecure.Lines.Add('PROBE  failed: ' + E.Message);
  end;
end;

{ ============================ MP4 tab (Phase 16) ================== }

procedure TfrmMain.RefreshMp4Tab;
begin
  if memMp4.Lines.Count = 0 then
    memMp4.Lines.Text :=
      'MP4/M4A is a real audio format here, not just a probe target: PCM,'#13#10 +
      'MP3 and AAC-LC/HE-AAC carried in an MP4 box all decode to engine PCM,'#13#10 +
      'play back through the audio engine, and can be dropped onto the'#13#10 +
      'Timeline as a non-destructive clip - the same path MP3 files use.'#13#10#13#10 +
      'Probe MP4...       - identify container brand + audio codec (AAC/ALAC/'#13#10 +
      '                     MP3/PCM), sample rate, channels, AudioSpecificConfig.'#13#10 +
      'Import MP4...      - decode the file to engine PCM (report only, no playback).'#13#10 +
      'Play / Stop        - audition the file live through the audio engine.'#13#10 +
      'Add to Timeline    - import as an undoable, non-destructive Timeline clip.'#13#10 +
      'Export test tone   - write a stereo tone into an MP4 as PCM 16/24/float.'#13#10 +
      'encode/decode verify - round-trip a generated tone through the writer + reader.'#13#10#13#10 +
      'Not yet decodable: ALAC, AAC SSR/Main/LTP/Scalable profiles (essentially'#13#10 +
      'unused by real-world encoders), and fragmented MP4. The container, codec'#13#10 +
      'identity and ASC are always fully reported by Probe either way.';
end;

procedure TfrmMain.btnMp4ProbeClick(Sender: TObject);
var
  info: TMP4ProbeInfo;
begin
  if not dlgOpenMp4.Execute then Exit;
  try
    if not Mp4ProbeFile(dlgOpenMp4.FileName, info) then
      memMp4.Lines.Text := 'not an MP4 (no ISO base-media header): ' + dlgOpenMp4.FileName
    else
      memMp4.Lines.Text := info.Describe;
  except
    on E: Exception do
      memMp4.Lines.Text := 'probe FAILED: ' + E.Message;
  end;
end;

procedure TfrmMain.btnMp4ImportClick(Sender: TObject);
var
  res: TMP4DecodeResult;
begin
  if not dlgOpenMp4.Execute then Exit;
  try
    if not Mp4DecodeAudioFile(dlgOpenMp4.FileName, res) then
      memMp4.Lines.Text := 'decode produced no audio: ' + dlgOpenMp4.FileName
    else
      memMp4.Lines.Text := Format(
        'imported "%s"'#13#10 +
        '  container : MP4 (brand %s)'#13#10 +
        '  codec     : %s'#13#10 +
        '  format    : %d Hz, %d ch'#13#10 +
        '  frames    : %d  (%.3f s)',
        [ExtractFileName(dlgOpenMp4.FileName), res.ContainerBrand, res.CodecName,
         res.SampleRate, res.Channels, res.Frames, res.Frames / Max(1, res.SampleRate)]);
    Logger.Info('ui', 'MP4 import: ' + dlgOpenMp4.FileName);
  except
    on E: Exception do
      memMp4.Lines.Text := 'import FAILED: ' + E.Message;
  end;
end;

function Mp4FmtFromCombo(AIndex: Integer): TMP4EncodeCodec;
begin
  case AIndex of
    1: Result := mecPCM24;
    2: Result := mecFloat32;
  else
    Result := mecPCM16;
  end;
end;

procedure TfrmMain.btnMp4ExportToneClick(Sender: TObject);
var
  sr, i, ch: Integer;
  pcm: TAudioPlanar;
begin
  if not RequireRegistration('Exporting MP4') then Exit;
  if not dlgSaveMp4.Execute then Exit;
  sr := 48000;
  EnsurePlanar(pcm, 2, sr);   // 1 s stereo
  for ch := 0 to 1 do
    for i := 0 to sr - 1 do
      pcm[ch][i] := 0.5 * Sin(2 * Pi * (330.0 + ch * 110.0) * i / sr);
  try
    if Mp4EncodeAudioToFile(pcm, sr, Mp4FmtFromCombo(cboMp4Fmt.ItemIndex), dlgSaveMp4.FileName) then
      memMp4.Lines.Text := Format('exported %s (%s, %d Hz stereo, 1.0 s)',
        [ExtractFileName(dlgSaveMp4.FileName), cboMp4Fmt.Text, sr])
    else
      memMp4.Lines.Text := 'export produced no file';
    Logger.Info('ui', 'MP4 test tone exported: ' + dlgSaveMp4.FileName);
  except
    on E: Exception do
      memMp4.Lines.Text := 'export FAILED: ' + E.Message;
  end;
end;

procedure TfrmMain.btnMp4RoundTripClick(Sender: TObject);
var
  sr, i, ch: Integer;
  pcm: TAudioPlanar;
  bytes: TBytes;
  dres: TMP4DecodeResult;
  info: TMP4ProbeInfo;
begin
  sr := 44100;
  EnsurePlanar(pcm, 2, sr);
  for ch := 0 to 1 do
    for i := 0 to sr - 1 do
      pcm[ch][i] := 0.5 * Sin(2 * Pi * (440.0 + ch * 220.0) * i / sr);
  try
    if not Mp4EncodeAudio(pcm, sr, Mp4FmtFromCombo(cboMp4Fmt.ItemIndex), bytes) then
    begin memMp4.Lines.Text := 'encode failed'; Exit; end;
    Mp4Probe(bytes, info);
    if not Mp4DecodeAudio(bytes, dres) then
    begin memMp4.Lines.Text := 'decode of the encoded stream failed'; Exit; end;
    memMp4.Lines.Text := Format(
      'PCM-in-MP4 round-trip OK'#13#10 +
      '  wrote     : %d bytes, %s'#13#10 +
      '  container : MP4 (%s)   codec: %s'#13#10 +
      '  decoded   : %d Hz, %d ch, %d frames'#13#10 +
      '  decodable : %s',
      [Length(bytes), cboMp4Fmt.Text, info.MajorBrand, info.CodecName,
       dres.SampleRate, dres.Channels, dres.Frames, BoolToStr(info.Decodable, True)]);
  except
    on E: Exception do
      memMp4.Lines.Text := 'round-trip FAILED: ' + E.Message;
  end;
end;

{ Import the selected MP4/M4A onto the timeline as an undoable non-destructive
  clip (TImportMp4Command), mirroring the MP3 add-clip path. }
procedure TfrmMain.btnMp4ToTimelineClick(Sender: TObject);
var
  tl: TTimeline;
  trackId: Integer;
  cmd: TImportMp4Command;
begin
  if FProject = nil then
  begin
    memMp4.Lines.Insert(0, 'open or create a project first');
    Exit;
  end;
  if not dlgOpenMp4.Execute then Exit;
  try
    if not Mp4SniffFile(dlgOpenMp4.FileName) then
    begin
      memMp4.Lines.Insert(0, 'not an MP4/M4A: ' + dlgOpenMp4.FileName);
      Exit;
    end;
    tl := FProject.Timeline;
    trackId := TlNewAudioTrackId;

    cmd := TImportMp4Command.Create(FProject, trackId, dlgOpenMp4.FileName,
      FTlView.Snap(tl.PlayheadSeconds), 0);
    FCmds.Perform(cmd);
    WarmClipWaveform(cmd.SourceId);
    FMp4Path := dlgOpenMp4.FileName;
    memMp4.Lines.Text := Format(
      'imported onto timeline: %s'#13#10 +
      '  %s, %d Hz, %d ch, %.3f s  (clip id %d)',
      [dlgOpenMp4.FileName, cmd.ImportedCodecName, cmd.ImportedSampleRate,
       cmd.ImportedChannels, cmd.ImportedLengthSeconds, cmd.CreatedClipId]);
    Logger.Info('ui', 'MP4 imported to timeline: ' + dlgOpenMp4.FileName);
    ApplyBaselineTempoOnImport(cmd.CreatedClipId);
    RefreshTimelineTab;
  except
    on E: Exception do
      memMp4.Lines.Insert(0, 'timeline import FAILED: ' + E.Message);
  end;
end;

{ Audition an MP4/M4A straight through the audio engine with a seekable
  streaming source (TMP4StreamSource). PCM-in-MP4 and MP3-in-MP4 play today;
  AAC-LC .m4a raises until Phase 16b's codebook tables land. }
procedure TfrmMain.btnMp4PlayClick(Sender: TObject);
var
  fn: string;
  src: TMP4StreamSource;
  devRate, devCh: Integer;
  t0: Cardinal;
  decodeMs: Cardinal;
  prevCursor: TCursor;
  engineStateMsg: string;
  openOk: Boolean;
begin
  if (FMp4Path <> '') and FileExists(FMp4Path) then
    dlgOpenMp4.FileName := FMp4Path;
  if not dlgOpenMp4.Execute then Exit;
  fn := dlgOpenMp4.FileName;
  try
    if not Mp4SniffFile(fn) then
    begin
      memMp4.Lines.Insert(0, 'not an MP4/M4A: ' + fn);
      Exit;
    end;
    FMp4Path := fn;

    { Decoding the whole file up front (TMP4StreamSource's design - see its
      header comment) runs synchronously on this, the UI thread.  For a
      several-minute file that is several seconds of real work with nothing
      on screen to show for it - which reads as a hang.  Give visible
      feedback before it starts and report how long it actually took, so a
      slow decode is at least visibly a decode and not an apparent freeze. }
    memMp4.Lines.Text := 'decoding "' + ExtractFileName(fn) + '" ...';
    prevCursor := Screen.Cursor;
    Screen.Cursor := crHourGlass;
    Application.ProcessMessages;
    t0 := GetTickCount;
    try
      src := TMP4StreamSource.CreateFromFile(fn, False);
    finally
      Screen.Cursor := prevCursor;
    end;
    decodeMs := GetTickCount - t0;
    FMp4Source := src;

    devRate := 0;
    devCh := 0;
    engineStateMsg := 'App is nil';
    openOk := True;
    if App <> nil then
    begin
      { Granted.SampleRate only becomes real once the device is actually
        open+running (TAudioEngine.Open negotiates the format and calls
        RefreshGranted).  Until then it reads back 0, and SetSource just
        Prepares the source against a guessed default rather than the real
        device format - which is exactly the "device rate: 0 Hz" this button
        was reporting.  Make Play self-sufficient: ensure the engine is
        actually running before attaching the source, the same way the Audio
        tab's Start button does, instead of silently assuming some other tab
        already did it this session.  Open() swallows its own exception and
        just sets aesFailed, so if the device genuinely won't open, surface
        that explicitly instead of leaving devRate=0 to look like the same
        cosmetic timing issue this used to be. }
      if App.Audio.State in [aesIdle, aesFailed] then
        openOk := App.Audio.Open(True)
      else if App.Audio.State <> aesRunning then
        App.Audio.Start;
      devRate := App.Audio.Granted.SampleRate;
      devCh := App.Audio.Granted.RenderChannels;
      engineStateMsg := Format('%s (backend %s)%s',
        [AudioEngineStateName(App.Audio.State), App.Audio.BackendName,
         IfThen(openOk, '', ' - Open() FAILED, see log')]);
      App.Audio.SetSource(FMp4Source);
    end;

    memMp4.Lines.Text := Format(
      'playing through the engine: %s'#13#10 +
      '  %s'#13#10 +
      '  file rate    : %d Hz'#13#10 +
      '  device rate  : %d Hz   %s'#13#10 +
      '  device chans : %d'#13#10 +
      '  audio engine : %s'#13#10 +
      '  decode time  : %.1f s',
      [fn, src.Name, src.SourceRate, devRate,
       IfThen(devRate = src.SourceRate, '(matches file - no resampling)',
                                        '(differs - Render resamples)'),
       devCh, engineStateMsg,
       decodeMs / 1000.0]);
    Logger.Info('ui', Format('MP4 streaming source started: %s (file %d Hz, device %d Hz/%d ch, engine %s, decode %d ms)',
      [fn, src.SourceRate, devRate, devCh, engineStateMsg, decodeMs]));
  except
    on E: Exception do
    begin
      Screen.Cursor := crDefault;
      FMp4Source := nil;
      memMp4.Lines.Insert(0, 'play FAILED: ' + E.Message);
    end;
  end;
end;

procedure TfrmMain.btnMp4StopClick(Sender: TObject);
begin
  if App <> nil then
    App.Audio.ClearSource;
  FMp4Source := nil;
  memMp4.Lines.Insert(0, 'playback stopped');
end;

{ ============================ Piano Roll tab (Phase 17) ========== }

function TfrmMain.CurrentMidiSeq: TMidiSequence;
begin
  Result := nil;
  if FProject = nil then Exit;
  if (FMidiClipIndex >= 0) and (FMidiClipIndex < FProject.Midi.ClipCount) then
    Result := FProject.Midi.Clip(FMidiClipIndex);
end;

function MidiGridDenom(AIndex: Integer): Integer;
begin
  case AIndex of
    0: Result := 4;
    1: Result := 8;
    3: Result := 32;
  else
    Result := 16;
  end;
end;

const
  MIDI_PR_LO_NOTE = 36;
  MIDI_PR_HI_NOTE = 96;

function TfrmMain.MidiRowHeight: Integer;
begin
  Result := Max(1, pbPianoRoll.Height div (MIDI_PR_HI_NOTE - MIDI_PR_LO_NOTE));
end;

function TfrmMain.MidiNoteAtY(AY: Integer): Integer;
begin
  Result := MIDI_PR_HI_NOTE - 1 - (AY div MidiRowHeight);
end;

function TfrmMain.MidiTickAtX(AX: Integer): Int64;
var
  seq: TMidiSequence;
  span: Int64;
  pxPerTick: Double;
begin
  Result := 0;
  seq := CurrentMidiSeq;
  if seq = nil then Exit;
  span := Max(seq.DurationTicks, seq.TicksPerBar(0) * 4);
  if span <= 0 then span := seq.PPQ * 16;
  pxPerTick := pbPianoRoll.Width / span;
  if pxPerTick <= 0 then Exit;
  Result := Round(AX / pxPerTick);
  if Result < 0 then Result := 0;
end;

function TfrmMain.MidiFindNoteAt(AX, AY: Integer; out ATrk: TMidiTrackSeq;
  out ANote: TMidiNote): Boolean;
var
  tick: Int64;
  note, i: Integer;
  n: TMidiNote;
begin
  Result := False;
  ATrk := nil;
  if CurrentMidiSeq = nil then Exit;
  ATrk := CurrentMidiSeq.GetTrack(FMidiTrackIndex);
  if ATrk = nil then Exit;
  tick := MidiTickAtX(AX);
  note := MidiNoteAtY(AY);
  for i := 0 to ATrk.NoteCount - 1 do
  begin
    n := ATrk.Notes[i];
    if (n.Note = note) and (tick >= n.StartTick) and (tick < n.EndTick) then
    begin
      ANote := n;
      Exit(True);
    end;
  end;
end;

{ 0 = start edge grabbed (resize from the left), 1 = end edge, -1 = neither -
  mirrors TlHitTestClipEdge's ~6px hit zone on the Timeline. }
function TfrmMain.MidiHitTestNoteEdge(const ANote: TMidiNote; AX: Integer): Integer;
const
  EDGE_PX = 6;
var
  seq: TMidiSequence;
  span: Int64;
  pxPerTick, x0, x1: Double;
begin
  Result := -1;
  seq := CurrentMidiSeq;
  if seq = nil then Exit;
  span := Max(seq.DurationTicks, seq.TicksPerBar(0) * 4);
  if span <= 0 then span := seq.PPQ * 16;
  pxPerTick := pbPianoRoll.Width / span;
  x0 := ANote.StartTick * pxPerTick;
  x1 := ANote.EndTick * pxPerTick;
  if Abs(AX - x1) <= EDGE_PX then Exit(1);
  if Abs(AX - x0) <= EDGE_PX then Exit(0);
end;

{ FMidiScaleType indexes cboMidiScaleType's items - see RefreshMidiTab. Used
  by pbPianoRollPaint to tint in-scale rows, matching FL Studio's piano roll
  "highlight scale" feature. }
function TfrmMain.MidiNoteInScale(ANote: Integer): Boolean;
type
  TScaleSet = set of 0..11;
const
  SCALES: array[0..3] of TScaleSet = (
    [0,2,4,5,7,9,11],   // Major
    [0,2,3,5,7,8,10],   // Natural minor
    [0,2,4,7,9],        // Major pentatonic
    [0,3,5,7,10]        // Minor pentatonic
  );
var
  pc: Integer;
begin
  if not FMidiScaleHighlight then Exit(True);
  if (FMidiScaleType < Low(SCALES)) or (FMidiScaleType > High(SCALES)) then Exit(True);
  pc := ((ANote - FMidiScaleRoot) mod 12 + 12) mod 12;
  Result := pc in SCALES[FMidiScaleType];
end;

procedure TfrmMain.RefreshMidiTab;
var
  i: Integer;
  seq: TMidiSequence;
begin
  if FMidiRefreshing then Exit;
  FMidiRefreshing := True;
  try
    cboMidiClip.Items.BeginUpdate;
    try
      cboMidiClip.Items.Clear;
      if FProject <> nil then
        for i := 0 to FProject.Midi.ClipCount - 1 do
          cboMidiClip.Items.Add(Format('%d: %s', [i, FProject.Midi.ClipName(i)]));
    finally
      cboMidiClip.Items.EndUpdate;
    end;
    if (FMidiClipIndex < 0) and (cboMidiClip.Items.Count > 0) then
      FMidiClipIndex := 0;
    if FMidiClipIndex >= cboMidiClip.Items.Count then
      FMidiClipIndex := cboMidiClip.Items.Count - 1;
    cboMidiClip.ItemIndex := FMidiClipIndex;

    seq := CurrentMidiSeq;
    if seq = nil then
      memMidi.Lines.Text :=
        'No MIDI clip yet.  "Add clip" creates one (PPQ 480, 4/4, 120 BPM).'#13#10 +
        'Then add notes (note/start/len/vel), quantize/humanize the track,'#13#10 +
        'Play through the internal poly synth, or Import/Export a .mid file.'
    else
      memMidi.Lines.Text := seq.Describe + sLineBreak +
        Format('editing track %d;  grid = 1/%d (%d ticks)',
          [FMidiTrackIndex, MidiGridDenom(cboMidiGrid.ItemIndex),
           GridTicks(seq, MidiGridDenom(cboMidiGrid.ItemIndex))]);
    pbPianoRoll.Invalidate;
  finally
    FMidiRefreshing := False;
  end;
end;

procedure TfrmMain.pbPianoRollPaint(Sender: TObject);
var
  c: TCanvas;
  w, h, loNote, hiNote, noteRange, i: Integer;
  seq: TMidiSequence;
  trk: TMidiTrackSeq;
  span, barTicks, t: Int64;
  x0, x1, y0, rowH, bx: Integer;
  n: TMidiNote;
  pxPerTick: Double;
begin
  c := pbPianoRoll.Canvas;
  w := pbPianoRoll.Width;
  h := pbPianoRoll.Height;
  c.Brush.Color := clWhite;
  c.FillRect(Rect(0, 0, w, h));

  loNote := MIDI_PR_LO_NOTE; hiNote := MIDI_PR_HI_NOTE;
  noteRange := hiNote - loNote;
  rowH := Max(1, h div noteRange);

  { horizontal key rows (grey for black keys); rows outside the selected
    scale get an extra dim wash when "Highlight scale" is on, so the usable
    notes stand out at a glance - MidiNoteInScale returns True for every row
    when the feature is off, so this is a no-op in that case }
  for i := 0 to noteRange - 1 do
  begin
    if MidiNoteIsBlack(hiNote - 1 - i) then c.Brush.Color := $00F0F0F0
    else c.Brush.Color := clWhite;
    c.FillRect(Rect(0, i * rowH, w, (i + 1) * rowH));
    if not MidiNoteInScale(hiNote - 1 - i) then
    begin
      c.Brush.Color := $00E8E8E8;
      c.FillRect(Rect(0, i * rowH, w, (i + 1) * rowH));
    end;
  end;

  seq := CurrentMidiSeq;
  if seq = nil then Exit;
  trk := seq.GetTrack(FMidiTrackIndex);
  if trk = nil then Exit;

  span := Max(seq.DurationTicks, seq.TicksPerBar(0) * 4);
  if span <= 0 then span := seq.PPQ * 16;
  pxPerTick := w / span;

  { bar lines }
  c.Pen.Color := $00D8D8D8;
  barTicks := seq.TicksPerBar(0);
  t := 0;
  while (barTicks > 0) and (t <= span) do
  begin
    bx := Round(t * pxPerTick);
    c.MoveTo(bx, 0); c.LineTo(bx, h);
    Inc(t, barTicks);
  end;

  { Ctrl+drag highlighted range }
  if FMidiRangeActive then
  begin
    c.Brush.Color := $00F5D9B8;
    c.FillRect(Rect(Round(FMidiRangeStart * pxPerTick), 0,
      Round(FMidiRangeEnd * pxPerTick), h));
  end;

  { notes }
  for i := 0 to trk.NoteCount - 1 do
  begin
    n := trk.Notes[i];
    if (n.Note < loNote) or (n.Note >= hiNote) then Continue;
    x0 := Round(n.StartTick * pxPerTick);
    x1 := Round(n.EndTick * pxPerTick);
    if x1 <= x0 then x1 := x0 + 2;
    y0 := (hiNote - 1 - n.Note) * rowH;
    if (n.Id = FMidiSelectedNoteId) or n.Selected then c.Brush.Color := $000080FF
    else c.Brush.Color := $00C08040;
    c.Pen.Color := clBlack;
    c.Rectangle(x0, y0, x1, y0 + rowH);
  end;
end;

{ Left-click an empty cell draws a new note (snapped to the grid, length one
  grid division, velocity from edtMidiVel); left-click an existing note
  selects it and starts a move-drag, or a resize-drag when the click lands
  within MidiHitTestNoteEdge's edge zone; right-click a note deletes it. All
  of this rides the same TAddMidiNoteCommand/TMoveMidiNoteCommand/
  TResizeMidiNoteCommand/TDeleteMidiNoteCommand undo stack btnMidi* already
  used - the commands existed since Phase 17, only the mouse wiring was
  missing. }
procedure TfrmMain.pbPianoRollMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  seq: TMidiSequence;
  trk: TMidiTrackSeq;
  n: TMidiNote;
  tick, len, gridLen: Int64;
  note, vv, edge: Integer;
begin
  seq := CurrentMidiSeq;
  if seq = nil then Exit;
  FMidiDragMode := mdmMidiNone;

  if Button = mbRight then
  begin
    if MidiFindNoteAt(X, Y, trk, n) then
    begin
      FCmds.Perform(TDeleteMidiNoteCommand.Create(FProject, FMidiClipIndex, FMidiTrackIndex, n.Id));
      if FMidiSelectedNoteId = n.Id then FMidiSelectedNoteId := -1;
      RefreshMidiTab;
    end;
    Exit;
  end;

  if Button <> mbLeft then Exit;

  if ssCtrl in Shift then
  begin
    gridLen := Max(Int64(1), GridTicks(seq, MidiGridDenom(cboMidiGrid.ItemIndex)));
    FMidiRangeDragging := True;
    FMidiRangeActive := False;
    FMidiRangeAnchor := (MidiTickAtX(X) div gridLen) * gridLen;
    FMidiRangeStart := FMidiRangeAnchor;
    FMidiRangeEnd := FMidiRangeAnchor;
    pbPianoRoll.Invalidate;
    Exit;
  end;
  FMidiRangeActive := False;

  if MidiFindNoteAt(X, Y, trk, n) then
  begin
    FMidiSelectedNoteId := n.Id;
    FMidiDragNoteId := n.Id;
    FMidiDragStartX := X;
    FMidiDragStartY := Y;
    FMidiDragAppliedTick := 0;
    FMidiDragAppliedNote := 0;
    edge := MidiHitTestNoteEdge(n, X);
    if edge = 0 then FMidiDragMode := mdmMidiResizeStart
    else if edge = 1 then FMidiDragMode := mdmMidiResizeEnd
    else FMidiDragMode := mdmMidiMove;
  end
  else
  begin
    gridLen := Max(Int64(1), GridTicks(seq, MidiGridDenom(cboMidiGrid.ItemIndex)));
    tick := (MidiTickAtX(X) div gridLen) * gridLen;
    len := gridLen;
    note := MidiNoteAtY(Y);
    vv := StrToIntDef(Trim(edtMidiVel.Text), 100);
    FCmds.Perform(TAddMidiNoteCommand.Create(FProject, FMidiClipIndex, FMidiTrackIndex,
      tick, len, note, vv, 0));
    trk := seq.GetTrack(FMidiTrackIndex);
    if (trk <> nil) and (trk.NoteCount > 0) then
      FMidiSelectedNoteId := trk.Notes[trk.NoteCount - 1].Id;
  end;
  RefreshMidiTab;
end;

procedure TfrmMain.pbPianoRollMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  trk: TMidiTrackSeq;
  hoverNote: TMidiNote;
  totalTick, incTick: Int64;
  totalNote, incNote: Integer;
begin
  if FMidiRangeDragging and (CurrentMidiSeq <> nil) then
  begin
    incTick := Max(Int64(1), GridTicks(CurrentMidiSeq, MidiGridDenom(cboMidiGrid.ItemIndex)));
    totalTick := (MidiTickAtX(X) div incTick) * incTick;
    FMidiRangeStart := Min(FMidiRangeAnchor, totalTick);
    FMidiRangeEnd := Max(FMidiRangeAnchor, totalTick);
    FMidiRangeActive := FMidiRangeEnd > FMidiRangeStart;
    pbPianoRoll.Invalidate;
    Exit;
  end;
  if FMidiDragMode = mdmMidiNone then
  begin
    { hover feedback: a resize cursor over a note's edge zone }
    if MidiFindNoteAt(X, Y, trk, hoverNote) and (MidiHitTestNoteEdge(hoverNote, X) >= 0) then
      pbPianoRoll.Cursor := crSizeWE
    else
      pbPianoRoll.Cursor := crDefault;
    Exit;
  end;
  if (CurrentMidiSeq = nil) or (FMidiDragNoteId < 0) then Exit;
  trk := CurrentMidiSeq.GetTrack(FMidiTrackIndex);
  if trk = nil then Exit;
  if trk.IndexOfNoteId(FMidiDragNoteId) < 0 then
  begin
    FMidiDragMode := mdmMidiNone;
    Exit;
  end;

  totalTick := MidiTickAtX(X) - MidiTickAtX(FMidiDragStartX);

  case FMidiDragMode of
    mdmMidiMove:
      begin
        totalNote := MidiNoteAtY(Y) - MidiNoteAtY(FMidiDragStartY);
        incTick := totalTick - FMidiDragAppliedTick;
        incNote := totalNote - FMidiDragAppliedNote;
        if (incTick <> 0) or (incNote <> 0) then
        begin
          FCmds.Perform(TMoveMidiNoteCommand.Create(FProject, FMidiClipIndex, FMidiTrackIndex,
            FMidiDragNoteId, incTick, incNote));
          FMidiDragAppliedTick := totalTick;
          FMidiDragAppliedNote := totalNote;
        end;
      end;
    mdmMidiResizeStart:
      begin
        { ResizeNote(..., AFromStart=True) subtracts the delta from
          StartTick, so a positive on-screen "drag right" (totalTick > 0,
          which should shrink the note) needs a negated delta here - see
          TPianoRoll.ResizeNote's header comment for the sign convention. }
        incTick := -totalTick - FMidiDragAppliedTick;
        if incTick <> 0 then
        begin
          FCmds.Perform(TResizeMidiNoteCommand.Create(FProject, FMidiClipIndex, FMidiTrackIndex,
            FMidiDragNoteId, incTick, True));
          FMidiDragAppliedTick := -totalTick;
        end;
      end;
    mdmMidiResizeEnd:
      begin
        incTick := totalTick - FMidiDragAppliedTick;
        if incTick <> 0 then
        begin
          FCmds.Perform(TResizeMidiNoteCommand.Create(FProject, FMidiClipIndex, FMidiTrackIndex,
            FMidiDragNoteId, incTick, False));
          FMidiDragAppliedTick := totalTick;
        end;
      end;
  end;
  RefreshMidiTab;
end;

procedure TfrmMain.pbPianoRollMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  FMidiDragMode := mdmMidiNone;
  FMidiRangeDragging := False;
end;

procedure TfrmMain.chkMidiScaleHighlightClick(Sender: TObject);
begin
  FMidiScaleHighlight := chkMidiScaleHighlight.Checked;
  pbPianoRoll.Invalidate;
end;

procedure TfrmMain.cboMidiScaleChange(Sender: TObject);
begin
  FMidiScaleRoot := Max(0, cboMidiScaleRoot.ItemIndex);
  FMidiScaleType := Max(0, cboMidiScaleType.ItemIndex);
  pbPianoRoll.Invalidate;
end;

procedure TfrmMain.cboMidiClipChange(Sender: TObject);
begin
  if FMidiRefreshing then Exit;
  FMidiClipIndex := cboMidiClip.ItemIndex;
  FMidiTrackIndex := 0;
  RefreshMidiTab;
end;

procedure TfrmMain.btnMidiAddClipClick(Sender: TObject);
begin
  if FProject = nil then Exit;
  FCmds.Perform(TAddMidiClipCommand.Create(FProject,
    Format('Clip %d', [FProject.Midi.ClipCount + 1]), MIDI_DEFAULT_PPQ));
  FMidiClipIndex := FProject.Midi.ClipCount - 1;
  FMidiTrackIndex := 0;
  RefreshMidiTab;
end;

procedure TfrmMain.btnMidiAddTrackClick(Sender: TObject);
begin
  if CurrentMidiSeq = nil then Exit;
  FCmds.Perform(TAddMidiTrackCommand.Create(FProject, FMidiClipIndex,
    Format('Track %d', [CurrentMidiSeq.TrackCount + 1])));
  FMidiTrackIndex := CurrentMidiSeq.TrackCount - 1;
  RefreshMidiTab;
end;

procedure TfrmMain.btnMidiAddNoteClick(Sender: TObject);
var
  nn, st, ln, vv: Integer;
begin
  if CurrentMidiSeq = nil then
  begin
    memMidi.Lines.Text := 'add a clip first';
    Exit;
  end;
  nn := StrToIntDef(Trim(edtMidiNote.Text), 60);
  st := StrToIntDef(Trim(edtMidiStart.Text), 0);
  ln := StrToIntDef(Trim(edtMidiLen.Text), CurrentMidiSeq.PPQ);
  vv := StrToIntDef(Trim(edtMidiVel.Text), 100);
  FCmds.Perform(TAddMidiNoteCommand.Create(FProject, FMidiClipIndex, FMidiTrackIndex,
    st, ln, nn, vv, 0));
  RefreshMidiTab;
end;

procedure TfrmMain.btnMidiDelNoteClick(Sender: TObject);
var
  trk: TMidiTrackSeq;
begin
  if CurrentMidiSeq = nil then Exit;
  trk := CurrentMidiSeq.GetTrack(FMidiTrackIndex);
  if (trk = nil) or (trk.NoteCount = 0) then Exit;
  FCmds.Perform(TDeleteMidiNoteCommand.Create(FProject, FMidiClipIndex, FMidiTrackIndex,
    trk.Notes[trk.NoteCount - 1].Id));
  RefreshMidiTab;
end;

procedure TfrmMain.btnMidiQuantizeClick(Sender: TObject);
var
  seq: TMidiSequence;
begin
  seq := CurrentMidiSeq;
  if seq = nil then Exit;
  FCmds.Perform(TQuantizeMidiCommand.Create(FProject, FMidiClipIndex, FMidiTrackIndex,
    GridTicks(seq, MidiGridDenom(cboMidiGrid.ItemIndex)), 1.0, 0.0, False, False));
  RefreshMidiTab;
end;

procedure TfrmMain.btnMidiHumanizeClick(Sender: TObject);
var
  seq: TMidiSequence;
begin
  seq := CurrentMidiSeq;
  if seq = nil then Exit;
  FCmds.Perform(THumanizeMidiCommand.Create(FProject, FMidiClipIndex, FMidiTrackIndex,
    Max(Int64(1), GridTicks(seq, 32) div 2), 12,
    Cardinal(seq.DurationTicks * 2654435761) or 1, False));
  RefreshMidiTab;
end;

procedure TfrmMain.btnMidiPlayClick(Sender: TObject);
var
  eng: TMidiPlaybackEngine;
begin
  if (App = nil) or (App.Audio = nil) or (CurrentMidiSeq = nil) then Exit;
  App.Audio.ClearSource;
  eng := TMidiPlaybackEngine.Create;
  FMidiEngine := eng;                 // hold as interface (ref-counted)
  FMidiEngineRef := eng;
  eng.SetSequence(CurrentMidiSeq);
  eng.SeekSeconds(0);
  eng.Play;
  FGraphPlaying := False;
  FWavPlaying := False;
  StopTimelinePlayback;
  App.Audio.SetSource(FMidiEngine);
  memMidi.Lines.Text := 'playing "' + FProject.Midi.ClipName(FMidiClipIndex) +
    '" through the internal poly synth';
end;

procedure TfrmMain.btnMidiStopClick(Sender: TObject);
begin
  if (App <> nil) and (App.Audio <> nil) then
    App.Audio.ClearSource;
  if FMidiEngineRef <> nil then
    FMidiEngineRef.Stop;
  FMidiEngine := nil;
  FMidiEngineRef := nil;
  RefreshMidiTab;
end;

{ Phase 38 - MIDI recording: toggles live capture from the Settings-selected
  MIDI input device straight onto the Timeline, mirroring the audio Record
  button's arm/stop shape (btnRecArmClick/StopLiveRecording) but far simpler
  - no disk-streaming take container, since a captured MIDI event stream is
  tiny; the whole performance lives in memory (FMidiCapture) until Stop
  commits it as one TCommitMidiTakeCommand. }
procedure TfrmMain.mnuMidiRecordClick(Sender: TObject);
var
  trk: TTimelineTrack;
  targetTrackId: Integer;
  seq: TMidiSequence;
  cmd: TCommitMidiTakeCommand;
  startSeconds, elapsedSinceStart: Double;
  clipName: string;
  nowDeviceMs: Int64;
begin
  if (App = nil) or (FProject = nil) or (FMidiCapture = nil) then Exit;

  if FMidiRecording then
  begin
    { ---- stop & commit ---- }
    nowDeviceMs := Int64(GetTickCount64) - Int64(FMidiInDevice.OpenTickCount64);
    elapsedSinceStart := (nowDeviceMs - Int64(FMidiRecStartTick)) / 1000.0;
    seq := FMidiCapture.Stop(elapsedSinceStart);
    FMidiRecording := False;
    mnuMidiRecord.Caption := 'Record from MIDI device';
    if seq = nil then
    begin
      memMidi.Lines.Insert(0, 'nothing captured - no notes/CC arrived from the input device');
      Exit;
    end;
    clipName := 'MIDI Take ' + FormatDateTime('hh:nn:ss', Now);
    cmd := TCommitMidiTakeCommand.Create(FProject, FMidiRecTrackId, seq, clipName,
      FMidiCapture.TimelineStartSeconds);
    FCmds.Perform(cmd);
    if FTlPlayer <> nil then FTlPlayer.InvalidateAllMidi;
    memMidi.Lines.Insert(0, Format('committed recorded MIDI ("%s") to the timeline', [clipName]));
    RefreshTimelineTab;
    Exit;
  end;

  { ---- arm & start ---- }
  if (FMidiInDevice = nil) or not FMidiInDevice.IsOpen then
  begin
    MessageDlg('Select a MIDI input device in Settings first.', mtInformation, [mbOK], 0);
    Exit;
  end;
  trk := FProject.Timeline.TrackById(FTlSelectedTrackId);
  if (trk <> nil) and (trk.Kind = tkMidi) then targetTrackId := trk.Id
  else targetTrackId := 0;   // TCommitMidiTakeCommand creates a fresh tkMidi track
  FMidiRecTrackId := targetTrackId;

  { the Timeline transport has to actually be rendering for the live monitor
    synth (AttachLiveMidiMonitor) to be audible - start it if it isn't
    already, exactly like arming audio recording does (btnRecArmClick). }
  if not FTlPlaying then
    StartTimelinePlayback(False, False, False);
  startSeconds := FProject.Timeline.PlayheadSeconds;

  FMidiRecStartTick := GetTickCount64 - FMidiInDevice.OpenTickCount64;
  FMidiCapture.Start(startSeconds, FProject.TempoBPM);
  FMidiRecording := True;
  mnuMidiRecord.Caption := 'Stop recording';
  memMidi.Lines.Insert(0, 'MIDI recording armed - play your controller now');
end;

procedure TfrmMain.btnMidiImportSMFClick(Sender: TObject);
var
  smf: TSmfFile;
  seq: TMidiSequence;
  nm: string;
begin
  if FProject = nil then Exit;
  if not dlgOpenMidi.Execute then Exit;
  smf := TSmfFile.Create;
  try
    try
      smf.LoadFromFile(dlgOpenMidi.FileName);
      seq := TMidiSequence.Create;
      seq.BuildFromSMF(smf);
      nm := ChangeFileExt(ExtractFileName(dlgOpenMidi.FileName), '');
      FProject.Midi.AddClip(nm, seq);
      FProject.Touch;
      FMidiClipIndex := FProject.Midi.ClipCount - 1;
      FMidiTrackIndex := 0;
      FCmds.Clear;
      memMidi.Lines.Text := 'imported ' + ExtractFileName(dlgOpenMidi.FileName) +
        sLineBreak + smf.Describe;
    except
      on E: Exception do
        memMidi.Lines.Text := 'import FAILED: ' + E.Message;
    end;
  finally
    smf.Free;
  end;
  RefreshMidiTab;
end;

procedure TfrmMain.btnMidiExportSMFClick(Sender: TObject);
var
  smf: TSmfFile;
begin
  if not RequireRegistration('Exporting MIDI') then Exit;
  if CurrentMidiSeq = nil then Exit;
  if not dlgSaveMidi.Execute then Exit;
  smf := CurrentMidiSeq.ToSMF(1);
  try
    try
      smf.SaveToFile(dlgSaveMidi.FileName);
      memMidi.Lines.Text := 'exported ' + ExtractFileName(dlgSaveMidi.FileName) +
        sLineBreak + smf.Describe;
    except
      on E: Exception do
        memMidi.Lines.Text := 'export FAILED: ' + E.Message;
    end;
  finally
    smf.Free;
  end;
end;

procedure TfrmMain.btnMidiUndoClick(Sender: TObject);
begin
  if FCmds.CanUndo then FCmds.Undo;
  RefreshMidiTab;
end;

procedure TfrmMain.btnMidiRedoClick(Sender: TObject);
begin
  if FCmds.CanRedo then FCmds.Redo;
  RefreshMidiTab;
end;

procedure TfrmMain.btnMidiDemoClick(Sender: TObject);
var
  seq: TMidiSequence;
  q, i: Integer;
  scale: array[0..7] of Integer;
begin
  seq := CurrentMidiSeq;
  if seq = nil then
  begin
    btnMidiAddClipClick(Sender);
    seq := CurrentMidiSeq;
    if seq = nil then Exit;
  end;
  q := seq.PPQ;
  scale[0] := 60; scale[1] := 62; scale[2] := 64; scale[3] := 65;
  scale[4] := 67; scale[5] := 69; scale[6] := 71; scale[7] := 72;
  for i := 0 to 7 do
    FCmds.Perform(TAddMidiNoteCommand.Create(FProject, FMidiClipIndex, FMidiTrackIndex,
      Int64(i) * (q div 2), q div 2 - 10, scale[i], 80 + (i mod 3) * 12, 0));
  RefreshMidiTab;
end;

{ ---- Settings: permanent / startup settings, working directories, visual
       theme.  Every control here is design-time; Load/Save just move values
       between the controls and App.Config ([audio]/[logging]/[general]/[ui]/
       [paths] sections - see UDAW.Config / UDAW.UI.Theme). }

procedure SelOrAddCombo(ACombo: TComboBox; const AValue: string);
var
  i: Integer;
begin
  i := ACombo.Items.IndexOf(AValue);
  if i < 0 then i := ACombo.Items.Add(AValue);
  ACombo.ItemIndex := i;
end;

procedure TfrmMain.ApplyDirDialogs;
begin
  if edDirAudioLib.Text <> '' then
  begin
    dlgOpenMp3.InitialDir := edDirAudioLib.Text;
    dlgOpenWav.InitialDir := edDirAudioLib.Text;
    dlgOpenMp4.InitialDir := edDirAudioLib.Text;
  end;
  if edDirExport.Text <> '' then
  begin
    dlgSaveMp3.InitialDir := edDirExport.Text;
    dlgSaveWav.InitialDir := edDirExport.Text;
  end;
  if edDirProjects.Text <> '' then
  begin
    dlgOpenProject.InitialDir := edDirProjects.Text;
    dlgSaveProject.InitialDir := edDirProjects.Text;
  end;
end;

procedure TfrmMain.RefreshInputDeviceCombo(const ASelectedDeviceId: string);
var
  devices: TAudioDeviceList;
  i, selIdx: Integer;
  displayName: string;
begin
  if App = nil then Exit;
  cboSetInDevice.Items.Clear;
  SetLength(FInputDeviceIds, 1);
  FInputDeviceIds[0] := '';
  cboSetInDevice.Items.Add('Default (system)');
  selIdx := 0;

  devices := App.Audio.EnumerateInputs;
  for i := 0 to High(devices) do
  begin
    displayName := devices[i].Name;
    if devices[i].IsDefault then
      displayName := displayName + ' (default)';
    SetLength(FInputDeviceIds, Length(FInputDeviceIds) + 1);
    FInputDeviceIds[High(FInputDeviceIds)] := devices[i].Id;
    cboSetInDevice.Items.Add(displayName);
    if (ASelectedDeviceId <> '') and SameText(devices[i].Id, ASelectedDeviceId) then
      selIdx := High(FInputDeviceIds);
  end;
  cboSetInDevice.ItemIndex := selIdx;
end;

{ Phase 38 - MIDI device I/O: same "sentinel + parallel id array" pattern as
  RefreshInputDeviceCombo above, but the parallel array holds device NAMEs -
  a MIDI driver index is not stable across replug/reboot the way this app
  already treats it for audio, so persistence and re-resolution both go
  through FindMidiInputByName/FindMidiOutputByName instead. }
procedure TfrmMain.RefreshMidiDeviceCombos(const ASelectedInName, ASelectedOutName: string);
var
  ins, outs: TMidiDeviceList;
  i, selIn, selOut: Integer;
begin
  cboSetMidiInDevice.Items.Clear;
  SetLength(FMidiInDeviceIds, 1);
  FMidiInDeviceIds[0] := '';
  cboSetMidiInDevice.Items.Add('(none)');
  selIn := 0;
  ins := EnumerateMidiInputs;
  for i := 0 to High(ins) do
  begin
    SetLength(FMidiInDeviceIds, Length(FMidiInDeviceIds) + 1);
    FMidiInDeviceIds[High(FMidiInDeviceIds)] := ins[i].Name;
    cboSetMidiInDevice.Items.Add(ins[i].Name);
    if (ASelectedInName <> '') and SameText(ins[i].Name, ASelectedInName) then
      selIn := High(FMidiInDeviceIds);
  end;
  cboSetMidiInDevice.ItemIndex := selIn;

  cboSetMidiOutDevice.Items.Clear;
  SetLength(FMidiOutDeviceIds, 1);
  FMidiOutDeviceIds[0] := '';
  cboSetMidiOutDevice.Items.Add('(none)');
  selOut := 0;
  outs := EnumerateMidiOutputs;
  for i := 0 to High(outs) do
  begin
    SetLength(FMidiOutDeviceIds, Length(FMidiOutDeviceIds) + 1);
    FMidiOutDeviceIds[High(FMidiOutDeviceIds)] := outs[i].Name;
    cboSetMidiOutDevice.Items.Add(outs[i].Name);
    if (ASelectedOutName <> '') and SameText(outs[i].Name, ASelectedOutName) then
      selOut := High(FMidiOutDeviceIds);
  end;
  cboSetMidiOutDevice.ItemIndex := selOut;

  if (Length(ins) = 0) and (Length(outs) = 0) then
    lblSetMidiStatus.Caption := 'no MIDI devices found'
  else
    lblSetMidiStatus.Caption := Format('%d in, %d out', [Length(ins), Length(outs)]);
end;

{ Opens whatever MIDI in/out devices are named in config (by name - see
  RefreshMidiDeviceCombos' comment), called at startup and again whenever
  the Settings tab pickers change. A device that is not currently plugged in
  just stays closed - same "degrade, don't fail" posture as audio device
  open (UDAW.Audio.Engine.Open's own comment). }
procedure TfrmMain.OpenMidiDevicesFromConfig;
var
  inName, outName: string;
  inId, outId: Integer;
begin
  if (App = nil) or (FMidiInDevice = nil) or (FMidiOutDevice = nil) then Exit;
  inName := App.Config.GetString(CFG_SEC_MIDI, CFG_MIDI_IN_DEVICE, '');
  outName := App.Config.GetString(CFG_SEC_MIDI, CFG_MIDI_OUT_DEVICE, '');

  FMidiInDevice.Close;
  if inName <> '' then
  begin
    inId := FindMidiInputByName(inName);
    if inId >= 0 then
      FMidiInDevice.Open(inId, inName);
  end;

  FMidiOutDevice.Close;
  if outName <> '' then
  begin
    outId := FindMidiOutputByName(outName);
    if outId >= 0 then
      FMidiOutDevice.Open(outId, outName);
  end;
end;

{ Called on the UI thread (see tmrUITimer -> FMidiInDevice.Poll) for every
  live event from the open MIDI input device: echoes it out the MIDI output
  device (hardware Thru, when chkMidiThru-style monitoring is wanted - here
  unconditional since sending to a closed/unset output device is a no-op),
  and feeds it to whichever is active: the live capture engine while
  recording (FMidiCapture.Feed, which also drives FMidiMonitorSynth via its
  own Monitor property), or straight to the monitor synth otherwise, so a
  connected controller is always audible through Timeline playback even
  outside a take (see TTimelinePlayer.AttachLiveMidiMonitor). }
procedure TfrmMain.HandleLiveMidiInput(Sender: TObject; const AMsg: TMidiMessage;
  ATimestampMs: Cardinal);
var
  elapsed: Double;
begin
  if (FMidiOutDevice <> nil) and FMidiOutDevice.IsOpen then
    FMidiOutDevice.SendMessage(AMsg);

  if FMidiRecording and (FMidiCapture <> nil) then
  begin
    elapsed := (Int64(ATimestampMs) - Int64(FMidiRecStartTick)) / 1000.0;
    FMidiCapture.Feed(AMsg, elapsed)
  end
  else if FMidiMonitorSynth <> nil then
    FMidiMonitorSynth.DispatchMessage(AMsg);
end;

procedure TfrmMain.cboSetMidiInDeviceChange(Sender: TObject);
begin
  if (cboSetMidiInDevice.ItemIndex >= 0) and (cboSetMidiInDevice.ItemIndex <= High(FMidiInDeviceIds)) then
    App.Config.SetString(CFG_SEC_MIDI, CFG_MIDI_IN_DEVICE, FMidiInDeviceIds[cboSetMidiInDevice.ItemIndex]);
  OpenMidiDevicesFromConfig;
end;

procedure TfrmMain.cboSetMidiOutDeviceChange(Sender: TObject);
begin
  if (cboSetMidiOutDevice.ItemIndex >= 0) and (cboSetMidiOutDevice.ItemIndex <= High(FMidiOutDeviceIds)) then
    App.Config.SetString(CFG_SEC_MIDI, CFG_MIDI_OUT_DEVICE, FMidiOutDeviceIds[cboSetMidiOutDevice.ItemIndex]);
  OpenMidiDevicesFromConfig;
end;

procedure TfrmMain.btnSetMidiRefreshClick(Sender: TObject);
var
  curIn, curOut: string;
begin
  if (cboSetMidiInDevice.ItemIndex >= 0) and (cboSetMidiInDevice.ItemIndex <= High(FMidiInDeviceIds)) then
    curIn := FMidiInDeviceIds[cboSetMidiInDevice.ItemIndex];
  if (cboSetMidiOutDevice.ItemIndex >= 0) and (cboSetMidiOutDevice.ItemIndex <= High(FMidiOutDeviceIds)) then
    curOut := FMidiOutDeviceIds[cboSetMidiOutDevice.ItemIndex];
  RefreshMidiDeviceCombos(curIn, curOut);
end;

procedure TfrmMain.btnSetMidiPanicClick(Sender: TObject);
begin
  if (FMidiOutDevice <> nil) and FMidiOutDevice.IsOpen then
    FMidiOutDevice.AllNotesOffAllChannels;
  if FMidiMonitorSynth <> nil then
    FMidiMonitorSynth.AllSoundOff;
end;

{ Rollover hint bubbles (UDAW.UI.Hints). Designer-set hints are kept; this
  fills in / overrides hint text for the controls below as "Title" + LF +
  body, then enables ShowHint on everything that has hint text. On/off is a
  system-wide setting (Settings > Show hints), not per project. }
procedure TfrmMain.InstallControlHints;
const
  TABLE: array[0..52] of array[0..2] of string = (
    ('edtProjectName', 'Project name', 'Shown in the title bar and used for the saved project file.'),
    ('edtProjectTempo', 'Tempo (BPM)', 'Project tempo. Drives the Timeline grid, tracker/MIDI timing and tempo-stretched clips.'),
    ('cboProjectSampleRate', 'Project sample rate', 'Internal rate for rendering and export. Clips at other rates are resampled.'),
    ('cboAutosaveInterval', 'Autosave', 'How often a crash-recovery copy of the project is written.'),
    ('cboMixStrip', 'Mixer strip', 'Choose the channel strip to edit its fader, pan, mute/solo, routing and inserts.'),
    ('edtMixFader', 'Fader', 'Strip level in dB.'),
    ('edtMixPan', 'Pan', '-100 = full left, 0 = centre, +100 = full right.'),
    ('chkMixMute', 'Mute', 'Silence this strip without changing its fader.'),
    ('chkMixSolo', 'Solo', 'Hear only soloed strips.'),
    ('btnMixAddVST', 'Add VST', 'Load a VST2 plug-in as an insert on the selected strip.'),
    ('btnMixEditVST', 'Edit VST', 'Open the selected plug-in''s own editor window.'),
    ('cboRecFormat', 'Take format', 'File format and bit depth recorded takes are written in.'),
    ('chkRecMonitor', 'Monitor', 'Hear the input through the output while recording.'),
    ('chkRecLoop', 'Loop record', 'Keep recording repeatedly across the loop range.'),
    ('btnRecArm', 'Arm / Record', 'Arm the input and start capturing a take.'),
    ('btnRecSaveTake', 'Save take', 'Save the selected take as a WAV file.'),
    ('btnRecAddTakeToTimeline', 'Add to Timeline', 'Place the selected take on a Timeline track at the playhead.'),
    ('btnRecCommitComp', 'Commit comp', 'Add one Timeline clip per comp segment (swipe across takes to build the comp).'),
    ('btnRecResetComp', 'Reset comp', 'Return the comp to take 1 for the whole lane.'),
    ('cboTlSnap', 'Snap', 'Grid resolution clips and the playhead snap to while editing.'),
    ('tbTlMasterVol', 'Master volume', 'Output level for Timeline playback and export.'),
    ('edtTlTempo', 'Timeline tempo', 'Timeline BPM; kept in sync with the Project tab.'),
    ('cboTrkInstrSel', 'Instrument', 'Pick which tracker instrument sample to inspect and export.'),
    ('btnTrkInstrAddTimeline', 'Add to Timeline', 'Bounce this instrument to a WAV in the Recordings folder and place it on the Timeline.'),
    ('btnTrkInstrSaveWav', 'Export sample', 'Export as WAV, raw PCM or FLAC. WAV carries loop points and all applied settings (volume, pan, fadeout, envelopes); PCM/FLAC get a .txt sidecar.'),
    ('cboMidiGrid', 'Grid', 'Note-length grid used for piano roll edits.'),
    ('chkMidiScaleHighlight', 'Scale highlight', 'Tint piano roll rows that belong to the chosen scale.'),
    ('cboSetBackend', 'Audio backend', 'auto picks the best device API; wasapi is Windows native; software renders without hardware.'),
    ('cboSetRate', 'Device rate', 'Sample rate requested from the audio device.'),
    ('cboSetBuffer', 'Buffer size', 'Smaller = lower latency but more risk of dropouts.'),
    ('chkSetExclusive', 'Exclusive mode', 'Take exclusive control of the device for the lowest latency. Other apps lose audio.'),
    ('chkSetCapture', 'Audio input', 'Enable audio capture; required for recording and voice control.'),
    ('cboSetInDevice', 'Input device', 'Microphone / line input used for recording.'),
    ('cboSetLogLevel', 'Log level', 'Minimum severity written to the log.'),
    ('chkSetTempoAuto', 'Auto-detect BPM', 'The first audio track you import sets the Timeline BPM.'),
    ('chkSetTempoResample', 'Resample tempo', 'Conform tempo by resampling (pitch follows) instead of the phase vocoder (pitch preserved).'),
    ('cboSetTheme', 'Visual theme', 'Application look. Applies immediately.'),
    ('cboDspSignal', 'Test signal', 'What to analyse: a synthetic tone/noise/sweep, or 1 second of your actual project mix.'),
    ('cboDspFilter', 'Filter', 'Biquad filter applied to the signal before analysis; the response is shown in the readout.'),
    ('cboDspWindow', 'FFT window', 'Window applied before the FFT. Blackman-Harris has the lowest leakage, Rectangular the narrowest peak.'),
    ('chkDspLive', 'Live', 'Re-run the analysis continuously.'),
    ('cboAdvDspProcess', 'Process', 'Advanced DSP process to run on the chosen signal.'),
    ('edtKey', 'Secret name', 'Name the secret is stored under in the OS-protected store (DPAPI on Windows).'),
    ('edtValue', 'Secret value', 'Value to protect. Only encrypted data is written to disk.'),
    ('btnBrowserRefresh', 'Refresh', 'Rescan the browser folders.'),
    ('btnBrowserImport', 'Import', 'Import the selected file into the project.'),
    ('cboAiProvider', 'AI provider', 'Which AI service handles chat, mixing help and composition.'),
    ('edtAiApiKey', 'API key', 'Stored encrypted in the OS secure store, never in the project or log.'),
    ('btnAiTest', 'Test', 'Verify the key and load the provider''s models.'),
    ('btnAiSend', 'Send', 'Send the prompt to the AI provider.'),
    ('btnSunoGenerate', 'Generate', 'Send the prompt to Suno and import the result on the Timeline.'),
    ('btnSunoCancel', 'Cancel', 'Cancel the running generation.'),
    ('chkSunoInstrumental', 'Instrumental', 'Generate without vocals.'));
  TABLE2: array[0..164] of array[0..2] of string = (
    ('edtProjectAuthor', 'Author', 'Name stored in the project file as its author.'),
    ('edtTimeSigNum', 'Time signature (beats)', 'Number of beats per bar, e.g. the 3 in 3/4. Drives the Timeline bar grid.'),
    ('edtTimeSigDen', 'Time signature (note value)', 'Note value that counts one beat, e.g. the 4 in 3/4.'),
    ('edtProjectChannels', 'Project channels', 'Number of output channels used when mixing and exporting (2 = stereo).'),
    ('memProject', 'Project summary', 'Read-only overview of the open project and its contents.'),
    ('cboMixTrackLink', 'Linked track', 'Timeline track this mixer strip processes and controls.'),
    ('cboMixRoute', 'Output route', 'Where this strip sends its audio: the master, a bus or another strip.'),
    ('cboMixInsertKind', 'Insert type', 'Built-in effect (EQ, compressor, reverb...) to add as an insert on the selected strip.'),
    ('cboMixAutoParam', 'Automation parameter', 'Strip parameter (fader, pan...) whose automation lane is shown and edited.'),
    ('cboMixAutoMode', 'Automation mode', 'How automation behaves during playback: off, read or write.'),
    ('tbMixZoom', 'Mixer zoom', 'Scale the channel strips larger or smaller.'),
    ('edtMixMeterHold', 'Meter peak hold', 'How long, in milliseconds, a peak marker stays on the level meters.'),
    ('edtMixMeterDecay', 'Meter decay', 'How fast the level meters fall back after a peak, in dB per second.'),
    ('btnMixMeterApply', 'Set meter timing', 'Apply the hold and decay values to all mixer meters.'),
    ('btnMixAddInsertRow', 'Add insert', 'Add a new insert row to the selected strip using the chosen insert type.'),
    ('btnMixDelInsertRow', 'Remove insert', 'Remove the selected insert from the strip.'),
    ('btnMixApplyRow', 'Apply', 'Commit the edited insert or strip settings to the mixer.'),
    ('btnMixUndoRow', 'Undo', 'Undo the last mixer change.'),
    ('btnMixRedoRow', 'Redo', 'Re-apply the mixer change you just undid.'),
    ('pbMixAuto', 'Automation lane', 'Click and drag to draw automation for the chosen parameter over time.'),
    ('memMix', 'Mixer log', 'Read-only details of the mixer state and recent actions.'),
    ('pbMixer', 'Mixer', 'Click a strip to select it. Drag faders and pan knobs, and use M / S to mute or solo.'),
    ('cboRecChannels', 'Input channels', 'Mono or stereo capture for new takes.'),
    ('edtRecDuration', 'Duration', 'Length to record in seconds. 0 records until you stop.'),
    ('edtRecPreRoll', 'Pre-roll', 'Seconds of audio played before the recording actually begins.'),
    ('edtRecCountIn', 'Count-in', 'Number of metronome beats played before recording starts.'),
    ('cboRecPunch', 'Punch mode', 'Record only between the punch-in and punch-out times.'),
    ('edtRecPunchIn', 'Punch in', 'Time in seconds where recording switches on.'),
    ('edtRecPunchOut', 'Punch out', 'Time in seconds where recording switches off.'),
    ('edtRecLoopStart', 'Loop start', 'Start time in seconds of the loop-record range.'),
    ('edtRecLoopEnd', 'Loop end', 'End time in seconds of the loop-record range.'),
    ('btnRecCommit', 'Retry adding take', 'Try again to place the last finished take onto the Timeline.'),
    ('btnRecSaved', 'Add saved audio', 'Choose an existing audio file and add it as a take.'),
    ('btnRecScan', 'Recover takes', 'Look for unfinished recordings left by a crash and rebuild them.'),
    ('memRec', 'Recording log', 'Read-only status of the capture engine and takes.'),
    ('pbRecTakes', 'Takes and comp lanes', 'Click a take to select it. Drag across takes to swipe-comp the best parts.'),
    ('chkTlMetronome', 'Metronome', 'Play a click at the project tempo during Timeline playback.'),
    ('pbTlMeters', 'Output meters', 'Left and right output levels, active during playback.'),
    ('memTimeline', 'Timeline log', 'Read-only details of Timeline actions and playback.'),
    ('sbTlHorz', 'Horizontal scroll', 'Scroll the Timeline along time.'),
    ('sbTlVert', 'Vertical scroll', 'Scroll through the Timeline channels.'),
    ('cboTrkPattern', 'Pattern', 'Choose which tracker pattern to view and edit.'),
    ('edtTrkSpeed', 'Speed', 'Ticks per row. Lower is faster.'),
    ('edtTrkBPM', 'Tracker BPM', 'Tick rate of the module. Combined with speed it sets the tempo.'),
    ('edtTrkNote', 'Note', 'Note entered into the selected cell, e.g. C-4.'),
    ('edtTrkInstr', 'Instrument number', 'Instrument the selected cell triggers.'),
    ('edtTrkVol', 'Volume column', 'Volume value of the selected cell.'),
    ('edtTrkEff', 'Effect', 'Effect command of the selected cell (arpeggio, slide, vibrato...).'),
    ('edtTrkParam', 'Effect parameter', 'Parameter value for the effect command.'),
    ('btnTrkSupport', 'ModPlug support', 'Open the ModPlug Tracker website.'),
    ('memTrk', 'Tracker log', 'Read-only module information and messages.'),
    ('pbTrkSequence', 'Order list', 'Click a position to jump to that pattern. Follows playback.'),
    ('sbTrkSeq', 'Order scroll', 'Scroll the order list.'),
    ('sbTrkChn', 'Channel scroll', 'Scroll the tracker channels.'),
    ('cboMidiClip', 'MIDI clip', 'Choose the MIDI clip shown in the piano roll.'),
    ('edtMidiNote', 'Note number', 'MIDI note number 0-127 for a new or edited note.'),
    ('edtMidiStart', 'Note start', 'Start position of the note in ticks.'),
    ('edtMidiLen', 'Note length', 'Length of the note in ticks.'),
    ('edtMidiVel', 'Velocity', 'How hard the note is played, 1-127.'),
    ('cboMidiScaleRoot', 'Scale root', 'Key note of the scale used for highlighting.'),
    ('cboMidiScaleType', 'Scale type', 'Major, minor, modes and other scales.'),
    ('pbPianoRoll', 'Piano roll', 'Click to add notes, drag to move, drag edges to resize, right-click to delete.'),
    ('memMidi', 'MIDI log', 'Read-only MIDI clip information.'),
    ('edSetOutCh', 'Output channels', 'Number of channels requested from the output device.'),
    ('edSetInCh', 'Input channels', 'Number of channels requested from the input device.'),
    ('chkSetAutostart', 'Auto-start audio', 'Start the audio engine automatically when UDAW launches.'),
    ('edSetLocale', 'Language', 'Locale code used for text, for example en.'),
    ('edDirProjects', 'Projects folder', 'Default folder for saving and opening projects.'),
    ('btnDirProjects', 'Browse', 'Choose the projects folder.'),
    ('edDirAudioLib', 'Audio library folder', 'Folder of your samples and loops, shown in the Browser.'),
    ('btnDirAudioLib', 'Browse', 'Choose the audio library folder.'),
    ('edDirSfx', 'SFX folder', 'Folder of sound effects, shown in the Browser.'),
    ('btnDirSfx', 'Browse', 'Choose the sound effects folder.'),
    ('edDirExport', 'Export folder', 'Default folder for rendered and exported files.'),
    ('btnDirExport', 'Browse', 'Choose the export folder.'),
    ('edDirRecordings', 'Recordings folder', 'Folder where recorded and generated takes are saved.'),
    ('btnDirRecordings', 'Browse', 'Choose the recordings folder.'),
    ('edDirTemp', 'Temporary files folder', 'Where UDAW puts scratch files while rendering, exporting and downloading. Leave empty for the default (your system temp folder). Point this at a drive with plenty of space if your C: drive is small. Takes effect the next time UDAW starts.'),
    ('btnDirTemp', 'Browse', 'Choose the temporary files folder.'),
    ('edDirCache', 'Cache files folder', 'Where UDAW keeps decoded and downloaded media it can rebuild. Leave empty for the default (under your user profile). Choose a roomier drive if your C: drive is small. Takes effect the next time UDAW starts.'),
    ('btnDirCache', 'Browse', 'Choose the cache files folder.'),
    ('memSysPaths', 'System locations', 'Read-only fixed folders UDAW uses for config, data, cache and logs.'),
    ('cboColorTheme', 'Colour theme', 'Colour set for waveforms, meters, piano roll and tracker.'),
    ('btnColorThemeSave', 'Save copy', 'Save the current colours as a new named theme.'),
    ('btnColorThemeReset', 'Reset', 'Restore the selected theme to its built-in colours.'),
    ('btnColorThemeExport', 'Export', 'Write the theme to a file you can share.'),
    ('btnColorThemeImport', 'Import', 'Load a theme file.'),
    ('cboSetMidiInDevice', 'MIDI input', 'Hardware MIDI keyboard or controller used for live playing and recording.'),
    ('cboSetMidiOutDevice', 'MIDI output', 'Hardware MIDI device that receives MIDI from UDAW.'),
    ('btnSetMidiRefresh', 'Refresh list', 'Rescan for MIDI devices.'),
    ('btnSetMidiPanic', 'MIDI panic', 'Silence every stuck note on all channels immediately.'),
    ('edtRegUsername', 'Username', 'The user name your licence was issued to.'),
    ('edtRegPassword', 'Password', 'Your account password.'),
    ('edtRegSerial', 'Serial number', 'Licence serial number.'),
    ('btnRegRegister', 'Register', 'Activate this copy of UDAW with your details.'),
    ('btnRegUnregister', 'Unregister', 'Release this licence so it can be used elsewhere.'),
    ('btnRegCheckUpdate', 'Check for updates', 'Ask the server whether a newer version is available.'),
    ('btnRegInstallUpdate', 'Install update', 'Download and install the newer version.'),
    ('lbColorSwatches', 'Colour list', 'Every themed colour. Select one to preview or change it.'),
    ('pbColorPreview', 'Colour preview', 'Shows the selected colour.'),
    ('btnColorPick', 'Change colour', 'Pick a new colour for the selected item.'),
    ('btnColorsSave', 'Save to theme', 'Store the edited colours in the current theme.'),
    ('btnColorsResetTheme', 'Reset theme colours', 'Discard edits and restore the theme defaults.'),
    ('cboFadeDisplay', 'Fade display', 'How clip fade curves are drawn on the Timeline.'),
    ('lvKeyHooks', 'Keyboard shortcuts', 'Every action and the key it is bound to.'),
    ('btnKeyHookAssign', 'Assign new key', 'Press a new key combination for the selected action.'),
    ('btnKeyHookSave', 'Save', 'Save the shortcut assignments.'),
    ('btnKeyHookRestore', 'Restore defaults', 'Return every shortcut to its original key.'),
    ('btnKeyHookToggle', 'Enable / disable', 'Turn the selected shortcut on or off.'),
    ('memSystem', 'System info', 'Read-only information about this machine and UDAW.'),
    ('lvJobs', 'Jobs', 'Running and finished background work with its progress.'),
    ('memAudio', 'Audio info', 'Read-only state of the audio engine and devices.'),
    ('memDspReadout', 'DSP readout', 'Numbers from the last analysis.'),
    ('pbSpectrum', 'Spectrum', 'Frequency spectrum of the analysed signal.'),
    ('cboGraphPreset', 'Graph preset', 'Load a ready-made audio graph to inspect and run.'),
    ('chkGraphLive', 'Live', 'Run the graph continuously.'),
    ('memGraph', 'Graph log', 'Read-only description of the graph and its validation.'),
    ('pbGraph', 'Graph view', 'Node layout of the audio graph.'),
    ('chkWavLoop', 'Loop', 'Loop the WAV when playing it.'),
    ('cboWavFormat', 'Write format', 'Sample format and bit depth used when writing WAV files.'),
    ('memWav', 'WAV log', 'Read-only WAV file details.'),
    ('memSecure', 'Secure log', 'Results of secure storage actions.'),
    ('cboMp3Bitrate', 'MP3 bitrate', 'Quality of MP3 files created; higher is larger and better.'),
    ('memMp3', 'MP3 log', 'Read-only MP3 details.'),
    ('cboMp4Fmt', 'MP4 format', 'Audio codec used when writing MP4/M4A files.'),
    ('memMp4', 'MP4 log', 'Read-only MP4 details.'),
    ('cboScopeSignal', 'Scope signal', 'Signal shown on the oscilloscope.'),
    ('cboScopeMode', 'Scope mode', 'Waveform, spectrum or other display style.'),
    ('chkScopeLive', 'Live', 'Refresh the scope continuously.'),
    ('memScopeReadout', 'Scope readout', 'Numeric values for the current view.'),
    ('pbScope', 'Scope', 'Live display of the chosen signal.'),
    ('cboAdvDspSignal', 'Source signal', 'Signal the advanced process works on.'),
    ('edtAdvDspParam', 'Process parameter', 'Main setting of the chosen process, e.g. amount or frequency.'),
    ('memAdvDspReadout', 'Advanced DSP readout', 'Results of the last process.'),
    ('btnBrowserAddFolder', 'Add folder', 'Add another folder to scan for audio.'),
    ('btnBrowserAddToSelected', 'Add to selected track', 'Place the selected file on the currently selected Timeline track.'),
    ('memBrowser', 'Browser info', 'Details of the selected file.'),
    ('tvBrowser', 'File browser', 'Drag a sample onto the Timeline, or a .dll onto the Mixer.'),
    ('cboAiModel', 'AI model', 'Model version to use with the chosen provider.'),
    ('btnAiSave', 'Save key', 'Encrypt and store the API key.'),
    ('btnAiDelete', 'Delete key', 'Remove the stored API key.'),
    ('edtAiMcpName', 'MCP server name', 'Friendly name for the MCP server you are adding.'),
    ('chkLumaTabOnly', 'Music Tabular Only', 'Write tablature/notation as text with your Claude/OpenAI/DeepSeek key (Luma cannot do music) and save it as a PDF in Recordings\AI\Rendered.'),
    ('edtAiMcpToken', 'MCP bearer token', 'Optional. Token sent to an HTTP MCP server; stored in the OS secure store, not in the server list.'),
    ('edtAiMcpCommand', 'MCP command', 'Command line that starts the MCP server.'),
    ('btnAiMcpTest', 'Test MCP', 'Start the server and list the tools it offers.'),
    ('chkAiMcpExpose', 'Expose UDAW', 'Let other AI clients control UDAW through an MCP server.'),
    ('edtAiMcpExposePort', 'MCP port', 'TCP port the UDAW MCP server listens on.'),
    ('chkAiMcpAllowDestructive', 'Allow destructive tools', 'Permit tools that delete or overwrite project content.'),
    ('lstAiMcpServers', 'MCP servers', 'Configured MCP servers.'),
    ('lstSunoRefs', 'Reference recordings', 'Recordings Suno can use as reference audio. Select one.'),
    ('btnSunoRefAdd', 'Add recording', 'Add an audio file as a reference recording.'),
    ('btnSunoRefRemove', 'Remove', 'Remove the selected reference recording.'),
    ('btnSunoRefRefresh', 'Refresh from folder', 'Rescan the Recordings folder.'),
    ('edtSunoPrompt', 'Song prompt', 'Describe the song you want Suno to generate.'),
    ('chkSunoCustom', 'Custom lyrics/style', 'Supply your own lyrics and style instead of a text prompt.'),
    ('edtSunoTitle', 'Song title', 'Title of the generated song.'),
    ('edtAiPrompt', 'AI prompt', 'Type a request for the AI: mixing help, composition or commands.'),
    ('btnAiClear', 'Clear', 'Clear the conversation.'),
    ('btnSunoTest', 'Test connection', 'Check the Suno server address and key.'),
    ('cboSunoApi', 'Suno API type', 'Which Suno service or proxy to talk to.'),
    ('edtSunoContinueAt', 'Continue at', 'Second in the reference audio where Suno should extend.'),
    ('memAiLog', 'AI log', 'Conversation and progress messages.'),
    ('lvLog', 'Log', 'Every message logged by UDAW.'),
    ('cboLevel', 'Log filter', 'Show only messages at or above this severity.'));
var
  i: Integer;
  c: TComponent;
begin
  for i := Low(TABLE) to High(TABLE) do
  begin
    c := FindComponent(TABLE[i][0]);
    if c is TControl then
      TControl(c).Hint := TABLE[i][1] + #10 + TABLE[i][2];
  end;
  for i := Low(TABLE2) to High(TABLE2) do
  begin
    c := FindComponent(TABLE2[i][0]);
    if c is TControl then
      TControl(c).Hint := TABLE2[i][1] + #10 + TABLE2[i][2];
  end;
  ActivateHintsFor(Self);
end;

procedure TfrmMain.LoadSettingsTab;
var
  cfg: TConfig;
  v: Integer;
  themes: TArray<string>;
  t: string;
begin
  if App = nil then Exit;
  cfg := App.Config;

  { the scrollbox auto-scrolls to keep whatever control last had focus in
    view, so a control focused deep in the page (e.g. while editing) can
    leave it scrolled down the next time this tab is shown - always land on
    top instead, like the tab is freshly opened. }
  sbSettings.VertScrollBar.Position := 0;

  { startup / audio engine }
  cboSetBackend.Items.Clear;
  cboSetBackend.Items.Add('auto');
  cboSetBackend.Items.Add('wasapi');
  cboSetBackend.Items.Add('software');
  SelOrAddCombo(cboSetBackend, cfg.GetString(CFG_SEC_AUDIO, CFG_AUDIO_BACKEND, 'auto'));

  cboSetRate.Items.Clear;
  cboSetRate.Items.Add('Device default');
  cboSetRate.Items.Add('44100');
  cboSetRate.Items.Add('48000');
  cboSetRate.Items.Add('88200');
  cboSetRate.Items.Add('96000');
  v := cfg.GetInt(CFG_SEC_AUDIO, CFG_AUDIO_RATE, 0);
  if v <= 0 then cboSetRate.ItemIndex := 0 else SelOrAddCombo(cboSetRate, IntToStr(v));

  cboSetBuffer.Items.Clear;
  cboSetBuffer.Items.Add('Device default');
  cboSetBuffer.Items.Add('128');
  cboSetBuffer.Items.Add('256');
  cboSetBuffer.Items.Add('512');
  cboSetBuffer.Items.Add('1024');
  cboSetBuffer.Items.Add('2048');
  v := cfg.GetInt(CFG_SEC_AUDIO, CFG_AUDIO_BUFFER, 0);
  if v <= 0 then cboSetBuffer.ItemIndex := 0 else SelOrAddCombo(cboSetBuffer, IntToStr(v));

  edSetOutCh.Text := IntToStr(cfg.GetInt(CFG_SEC_AUDIO, CFG_AUDIO_OUT_CH, 2));
  edSetInCh.Text := IntToStr(cfg.GetInt(CFG_SEC_AUDIO, CFG_AUDIO_IN_CH, 2));
  RefreshInputDeviceCombo(cfg.GetString(CFG_SEC_AUDIO, CFG_AUDIO_IN_DEVICE, ''));
  RefreshMidiDeviceCombos(cfg.GetString(CFG_SEC_MIDI, CFG_MIDI_IN_DEVICE, ''),
    cfg.GetString(CFG_SEC_MIDI, CFG_MIDI_OUT_DEVICE, ''));
  chkSetAutostart.Checked := cfg.GetBool(CFG_SEC_AUDIO, CFG_AUDIO_AUTOSTART, True);
  chkSetCapture.Checked := cfg.GetBool(CFG_SEC_AUDIO, CFG_AUDIO_CAPTURE, False);
  chkSetExclusive.Checked := cfg.GetBool(CFG_SEC_AUDIO, CFG_AUDIO_EXCLUSIVE, False);

  cboSetLogLevel.Items.Clear;
  cboSetLogLevel.Items.Add('trace');
  cboSetLogLevel.Items.Add('debug');
  cboSetLogLevel.Items.Add('info');
  cboSetLogLevel.Items.Add('warn');
  cboSetLogLevel.Items.Add('error');
  cboSetLogLevel.Items.Add('critical');
  SelOrAddCombo(cboSetLogLevel, cfg.GetString(CFG_SEC_LOGGING, CFG_LOG_LEVEL, 'info'));

  edSetLocale.Text := cfg.GetString(CFG_SEC_GENERAL, CFG_GEN_LOCALE, 'en');
  chkSetTempoAuto.Checked := cfg.GetBool(CFG_SEC_GENERAL, CFG_GEN_TEMPO_AUTO, True);
  chkSetTempoResample.Checked := cfg.GetBool(CFG_SEC_GENERAL, CFG_GEN_TEMPO_RESAMPLE, False);
  chkSetHints.Checked := cfg.GetBool(CFG_SEC_GENERAL, CFG_GEN_SHOW_HINTS, True);
  SetUDAWHintsEnabled(chkSetHints.Checked);
  TimelineResampleTempo := chkSetTempoResample.Checked;

  { visual theme }
  cboSetTheme.Items.Clear;
  themes := ThemeAvailable;
  for t in themes do cboSetTheme.Items.Add(t);
  SelOrAddCombo(cboSetTheme, ThemeCurrent);
  if ThemeStylesDir <> '' then
    lblThemeInfo.Caption := Format('%d style(s) loaded from %s', [Length(themes) - 1, ThemeStylesDir])
  else
    lblThemeInfo.Caption := 'no resources\styles folder found - only the built-in look is available';

  { Phase 29: colour theme (independent of the VCL style above - this one
    drives CurrentTheme.* for the custom-drawn waveform/meter/tracker/piano-
    roll surfaces, not native control skinning). }
  ThemeColorsInitFromConfig(cfg);
  cboColorTheme.Items.Clear;
  for t in ThemeColorsAvailable do cboColorTheme.Items.Add(t);
  SelOrAddCombo(cboColorTheme, ThemeColorsCurrent.Name);
  lblColorThemeStatus.Caption := ' ';
  LoadColorsTab;
  LoadKeyHooksTab;

  { working directories }
  edDirProjects.Text := cfg.GetString(CFG_SEC_PATHS, CFG_PATH_PROJECTS, '');
  edDirAudioLib.Text := cfg.GetString(CFG_SEC_PATHS, CFG_PATH_AUDIO_LIB, '');
  edDirSfx.Text := cfg.GetString(CFG_SEC_PATHS, CFG_PATH_SFX, '');
  edDirExport.Text := cfg.GetString(CFG_SEC_PATHS, CFG_PATH_EXPORT, '');
  edDirRecordings.Text := cfg.GetString(CFG_SEC_PATHS, CFG_PATH_RECORDINGS, '');
  var ovTemp, ovCache: string;
  LoadFolderOverrides(ovTemp, ovCache);
  edDirTemp.Text := ovTemp;
  edDirCache.Text := ovCache;
  ApplyDirDialogs;

  { system locations - fixed per-OS roots, read-only }
  memSysPaths.Lines.Text :=
    'Config      : ' + Paths.Config + sLineBreak +
    'Data        : ' + Paths.Data + sLineBreak +
    'Cache       : ' + Paths.Cache + sLineBreak +
    'Logs        : ' + Paths.Logs + sLineBreak +
    'Temp        : ' + Paths.Temp + sLineBreak +
    'Config file : ' + cfg.Path + sLineBreak +
    'Executable  : ' + Paths.ExecutableFile;

  lblSettingsStatus.Caption := ' ';
end;

procedure TfrmMain.SaveSettingsTab;
var
  cfg: TConfig;
  rate, buf, outCh, inCh: Integer;
begin
  if App = nil then Exit;
  cfg := App.Config;

  cfg.SetString(CFG_SEC_AUDIO, CFG_AUDIO_BACKEND, cboSetBackend.Text);

  if (cboSetRate.ItemIndex = 0) or not TryStrToInt(cboSetRate.Text, rate) then rate := 0;
  cfg.SetInt(CFG_SEC_AUDIO, CFG_AUDIO_RATE, rate);

  if (cboSetBuffer.ItemIndex = 0) or not TryStrToInt(cboSetBuffer.Text, buf) then buf := 0;
  cfg.SetInt(CFG_SEC_AUDIO, CFG_AUDIO_BUFFER, buf);

  if not TryStrToInt(edSetOutCh.Text, outCh) or (outCh < 1) then outCh := 2;
  if not TryStrToInt(edSetInCh.Text, inCh) or (inCh < 1) then inCh := 2;
  cfg.SetInt(CFG_SEC_AUDIO, CFG_AUDIO_OUT_CH, outCh);
  cfg.SetInt(CFG_SEC_AUDIO, CFG_AUDIO_IN_CH, inCh);

  if (cboSetInDevice.ItemIndex >= 0) and (cboSetInDevice.ItemIndex <= High(FInputDeviceIds)) then
    cfg.SetString(CFG_SEC_AUDIO, CFG_AUDIO_IN_DEVICE, FInputDeviceIds[cboSetInDevice.ItemIndex])
  else
    cfg.SetString(CFG_SEC_AUDIO, CFG_AUDIO_IN_DEVICE, '');

  cfg.SetBool(CFG_SEC_AUDIO, CFG_AUDIO_AUTOSTART, chkSetAutostart.Checked);
  cfg.SetBool(CFG_SEC_AUDIO, CFG_AUDIO_CAPTURE, chkSetCapture.Checked);
  cfg.SetBool(CFG_SEC_AUDIO, CFG_AUDIO_EXCLUSIVE, chkSetExclusive.Checked);

  cfg.SetString(CFG_SEC_LOGGING, CFG_LOG_LEVEL, cboSetLogLevel.Text);
  if (cboSetLogLevel.ItemIndex >= Ord(Low(TLogLevel))) and
     (cboSetLogLevel.ItemIndex <= Ord(High(TLogLevel))) then
    Logger.SetMinLevel(TLogLevel(cboSetLogLevel.ItemIndex));

  cfg.SetString(CFG_SEC_GENERAL, CFG_GEN_LOCALE, Trim(edSetLocale.Text));
  cfg.SetBool(CFG_SEC_GENERAL, CFG_GEN_TEMPO_AUTO, chkSetTempoAuto.Checked);
  cfg.SetBool(CFG_SEC_GENERAL, CFG_GEN_TEMPO_RESAMPLE, chkSetTempoResample.Checked);
  cfg.SetBool(CFG_SEC_GENERAL, CFG_GEN_SHOW_HINTS, chkSetHints.Checked);
  SetUDAWHintsEnabled(chkSetHints.Checked);
  TimelineResampleTempo := chkSetTempoResample.Checked;

  { theme: applied live, remembered for next launch }
  if cboColorTheme.ItemIndex >= 0 then
  begin
    ThemeColorsApply(cboColorTheme.Text);
    ThemeColorsSaveToConfig(cfg, cboColorTheme.Text);
    Invalidate;   // repaint every custom-drawn surface with the new colours
  end;

  if cboSetTheme.ItemIndex >= 0 then
  begin
    ThemeApply(cboSetTheme.Text);
    ThemeSaveToConfig(cfg, cboSetTheme.Text);
  end;

  { working directories }
  cfg.SetString(CFG_SEC_PATHS, CFG_PATH_PROJECTS, Trim(edDirProjects.Text));
  cfg.SetString(CFG_SEC_PATHS, CFG_PATH_AUDIO_LIB, Trim(edDirAudioLib.Text));
  cfg.SetString(CFG_SEC_PATHS, CFG_PATH_SFX, Trim(edDirSfx.Text));
  cfg.SetString(CFG_SEC_PATHS, CFG_PATH_EXPORT, Trim(edDirExport.Text));
  cfg.SetString(CFG_SEC_PATHS, CFG_PATH_RECORDINGS, Trim(edDirRecordings.Text));
  ApplyDirDialogs;

  { Temp / Cache live in a bootstrap file (they are read before the config
    exists at startup), and apply from the next launch. }
  var wantTemp := Trim(edDirTemp.Text);
  var wantCache := Trim(edDirCache.Text);
  var curTemp, curCache: string;
  LoadFolderOverrides(curTemp, curCache);
  if (wantTemp <> curTemp) or (wantCache <> curCache) then
  begin
    if ((wantTemp <> '') and not ForceDirectories(wantTemp)) or
       ((wantCache <> '') and not ForceDirectories(wantCache)) then
      MessageDlg('One of the Temp / Cache folders could not be created or is not writable. ' +
        'Those two settings were not changed.', mtWarning, [mbOK], 0)
    else
    begin
      SaveFolderOverrides(wantTemp, wantCache);
      MessageDlg('Temp / Cache folder changes take effect the next time UDAW starts.',
        mtInformation, [mbOK], 0);
    end;
  end;

  if cfg.Save then
    lblSettingsStatus.Caption := 'saved ' + FormatDateTime('hh:nn:ss', Now)
  else
    lblSettingsStatus.Caption := 'SAVE FAILED - see log';
  Logger.Info('ui', 'settings saved (' + cfg.Path + ')');
end;

procedure TfrmMain.btnSettingsSaveClick(Sender: TObject);
begin
  if FRecWriter <> nil then
  begin
    MessageDlg('Stop live recording before changing the project or audio input.', mtInformation, [mbOK], 0);
    Exit;
  end;
  SaveSettingsTab;
end;

procedure TfrmMain.btnSettingsReloadClick(Sender: TObject);
begin
  LoadSettingsTab;
  if App <> nil then
    lblSettingsStatus.Caption := 'reloaded from ' + App.Config.Path;
end;

procedure TfrmMain.cboSetThemeChange(Sender: TObject);
begin
  { live preview; Save persists it }
  if cboSetTheme.ItemIndex >= 0 then
    ThemeApply(cboSetTheme.Text);
end;

{ ---- Phase 29: colour theme editor support (Theme Editor / Save / Export /
  Import / Reset, plan section 47). There is no per-swatch colour-picker UI
  here (that would need many more designed controls than this settings page
  has room for); "Save copy..." instead lets the user name the *current*
  in-memory theme and keep it - the practical editing path most users need
  (duplicate a built-in, or re-save one they imported, under their own
  name) - while Export/Import/Reset cover the rest of the plan's bullet
  list. ---- }

procedure TfrmMain.cboColorThemeChange(Sender: TObject);
begin
  if cboColorTheme.ItemIndex >= 0 then
  begin
    ThemeColorsApply(cboColorTheme.Text);
    Invalidate;
    LoadColorsTab;
  end;
end;

procedure TfrmMain.btnColorThemeSaveClick(Sender: TObject);
var
  name: string;
  theme: TUDAWTheme;
begin
  name := ThemeColorsCurrent.Name;
  if not InputQuery('Save Theme', 'Save the current theme as:', name) then Exit;
  name := Trim(name);
  if name = '' then Exit;
  theme := ThemeColorsCurrent;
  theme.Name := name;
  if ThemeColorsSave(theme) then
  begin
    LoadSettingsTab;
    SelOrAddCombo(cboColorTheme, name);
    ThemeColorsApply(name);
    lblColorThemeStatus.Caption := 'saved "' + name + '"';
  end
  else
    lblColorThemeStatus.Caption := 'SAVE FAILED - see log';
end;

procedure TfrmMain.btnColorThemeResetClick(Sender: TObject);
begin
  if cboColorTheme.ItemIndex < 0 then Exit;
  if ThemeColorsReset(cboColorTheme.Text) then
  begin
    ThemeColorsApply(cboColorTheme.Text);
    Invalidate;
    LoadColorsTab;
    lblColorThemeStatus.Caption := 'reset "' + cboColorTheme.Text + '" to its built-in colours';
  end
  else
    lblColorThemeStatus.Caption := '"' + cboColorTheme.Text + '" has no saved edit to reset';
end;

procedure TfrmMain.btnColorThemeExportClick(Sender: TObject);
var
  dlg: TSaveDialog;
begin
  if not RequireRegistration('Exporting a colour theme') then Exit;
  dlg := TSaveDialog.Create(Self);
  try
    dlg.DefaultExt := 'udawtheme';
    dlg.Filter := 'UDAW theme (*.udawtheme)|*.udawtheme|All files (*.*)|*.*';
    dlg.FileName := ThemeColorsCurrent.Name + '.udawtheme';
    if dlg.Execute then
    begin
      if ThemeColorsExport(ThemeColorsCurrent, dlg.FileName) then
        lblColorThemeStatus.Caption := 'exported to ' + dlg.FileName
      else
        lblColorThemeStatus.Caption := 'EXPORT FAILED - see log';
    end;
  finally
    dlg.Free;
  end;
end;

procedure TfrmMain.btnColorThemeImportClick(Sender: TObject);
var
  dlg: TOpenDialog;
  theme: TUDAWTheme;
begin
  dlg := TOpenDialog.Create(Self);
  try
    dlg.DefaultExt := 'udawtheme';
    dlg.Filter := 'UDAW theme (*.udawtheme)|*.udawtheme|All files (*.*)|*.*';
    dlg.Options := [ofFileMustExist];
    if dlg.Execute then
    begin
      if ThemeColorsImport(dlg.FileName, theme) then
      begin
        LoadSettingsTab;
        SelOrAddCombo(cboColorTheme, theme.Name);
        ThemeColorsApply(theme.Name);
        Invalidate;
        lblColorThemeStatus.Caption := 'imported "' + theme.Name + '"';
      end
      else
        lblColorThemeStatus.Caption := 'IMPORT FAILED - not a valid theme file';
    end;
  finally
    dlg.Free;
  end;
end;

{ ---- Colors settings page: a data-driven swatch list over every semantic
  colour role in TUDAWTheme (waveform, selection highlight, meters, log
  levels, ...) - one designed TListBox + TColorDialog instead of one designed
  control per swatch. Edits apply live (ThemeColorsSetCurrent + Invalidate)
  so every custom-drawn surface repaints immediately; "Save to Theme" is what
  actually persists them to <data>/themes/<name>.udawtheme so they reload on
  the next startup (ThemeColorsInitFromConfig already re-applies whatever
  theme name was last selected, in LoadSettingsTab -> LoadColorsTab). }
procedure TfrmMain.LoadColorsTab;
var
  sw: TColorSwatch;
  theme: TUDAWTheme;
begin
  cboFadeDisplay.ItemIndex := Ord(CurrentFadeDisplay);
  theme := ThemeColorsCurrent;
  lblColorsTitle.Caption := 'Editing theme: ' + theme.Name +
    '  (pick a different theme to edit on the Settings tab)';
  if lbColorSwatches.Items.Count = 0 then
  begin
    SetLength(FColorSwatchList, 0);
    lbColorSwatches.Items.BeginUpdate;
    try
      for sw := Low(TColorSwatch) to High(TColorSwatch) do
      begin
        if sw in [csLogTrace, csLogDebug, csLogInfo] then Continue;
        SetLength(FColorSwatchList, Length(FColorSwatchList) + 1);
        FColorSwatchList[High(FColorSwatchList)] := sw;
        lbColorSwatches.Items.Add(ColorSwatchName(sw));
      end;
    finally
      lbColorSwatches.Items.EndUpdate;
    end;
  end;
  if lbColorSwatches.ItemIndex < 0 then
    lbColorSwatches.ItemIndex := 0;
  lbColorSwatchesClick(lbColorSwatches);
  lblColorsStatus.Caption := ' ';
end;

procedure TfrmMain.lbColorSwatchesClick(Sender: TObject);
begin
  if (lbColorSwatches.ItemIndex < 0) or (lbColorSwatches.ItemIndex > High(FColorSwatchList)) then Exit;
  FColorPreviewColor := ColorSwatchGet(ThemeColorsCurrent, FColorSwatchList[lbColorSwatches.ItemIndex]);
  pbColorPreview.Invalidate;
end;

{ Paints a plain filled rectangle in the actual swatch colour, via Canvas -
  not a themed control's .Color property, which an active VCL style (see
  UDAW.UI.Theme) can override with its own chrome regardless of what the
  control's Color is set to. This is the same reason every other "show an
  exact colour" surface in this app (waveform, meters, Timeline clips) is a
  custom-painted TPaintBox rather than a styled control. }
procedure TfrmMain.pbColorPreviewPaint(Sender: TObject);
var
  cv: TCanvas;
  w, h: Integer;
begin
  cv := pbColorPreview.Canvas;
  w := pbColorPreview.Width;
  h := pbColorPreview.Height;
  cv.Brush.Style := bsSolid;
  cv.Brush.Color := FColorPreviewColor;
  cv.Pen.Color := CurrentTheme.Border;
  cv.Rectangle(0, 0, w, h);
end;

procedure TfrmMain.btnColorPickClick(Sender: TObject);
var
  sw: TColorSwatch;
  theme: TUDAWTheme;
  dlg: TColorDialog;
begin
  if (lbColorSwatches.ItemIndex < 0) or (lbColorSwatches.ItemIndex > High(FColorSwatchList)) then Exit;
  sw := FColorSwatchList[lbColorSwatches.ItemIndex];
  theme := ThemeColorsCurrent;
  dlg := TColorDialog.Create(Self);
  try
    dlg.Color := ColorSwatchGet(theme, sw);
    dlg.Options := [cdFullOpen];
    if dlg.Execute then
    begin
      ColorSwatchSet(theme, sw, dlg.Color);
      ThemeColorsSetCurrent(theme);
      FColorPreviewColor := dlg.Color;
      pbColorPreview.Invalidate;
      Invalidate;
      lblColorsStatus.Caption := 'changed - click "Save to Theme" to keep it after restart';
    end;
  finally
    dlg.Free;
  end;
end;

procedure TfrmMain.cboFadeDisplayChange(Sender: TObject);
begin
  if cboFadeDisplay.ItemIndex < 0 then Exit;
  SetFadeDisplay(TFadeDisplayMode(cboFadeDisplay.ItemIndex), App.Config);
  App.Config.Save;
  pbTimeline.Invalidate;
end;

procedure TfrmMain.btnColorsSaveClick(Sender: TObject);
begin
  if ThemeColorsSave(ThemeColorsCurrent) then
    lblColorsStatus.Caption := 'saved "' + ThemeColorsCurrent.Name + '"'
  else
    lblColorsStatus.Caption := 'SAVE FAILED - see log';
end;

procedure TfrmMain.btnColorsResetThemeClick(Sender: TObject);
var
  name: string;
begin
  name := ThemeColorsCurrent.Name;
  if ThemeColorsReset(name) then
  begin
    LoadColorsTab;
    Invalidate;
    lblColorsStatus.Caption := 'reset "' + name + '" to its built-in colours';
  end
  else
    lblColorsStatus.Caption := '"' + name + '" has no saved edit to reset';
end;

{ Colours each row of the Log tab by severity (theme.LogTrace/.../LogCritical)
  - PumpLog stashes the TLogLevel ordinal in TListItem.Data when it adds the
  row, since a plain TListView has no per-item font colour of its own without
  OwnerDraw/custom-draw. }
procedure TfrmMain.lvLogCustomDrawItem(Sender: TCustomListView; Item: TListItem;
  State: TCustomDrawState; var DefaultDraw: Boolean);
var
  theme: TUDAWTheme;
begin
  { Trace/Debug/Info are left completely alone (default text colour) - only
    the levels that actually need attention get coloured, so routine logging
    doesn't turn into a multi-colour wall of text. }
  case TLogLevel(NativeInt(Item.Data)) of
    llWarn, llError, llCritical:
      begin
        theme := CurrentTheme;
        case TLogLevel(NativeInt(Item.Data)) of
          llWarn:     Sender.Canvas.Font.Color := theme.LogWarn;
          llError:    Sender.Canvas.Font.Color := theme.LogError;
          llCritical: Sender.Canvas.Font.Color := theme.LogCritical;
        end;
      end;
  end;
  DefaultDraw := True;
end;

procedure TfrmMain.btnSettingsBrowseDirClick(Sender: TObject);
var
  ed: TEdit;
  cap, dir: string;
begin
  ed := nil;
  cap := 'Select a folder';
  case (Sender as TButton).Tag of
    1: begin ed := edDirProjects;   cap := 'Projects folder'; end;
    2: begin ed := edDirAudioLib;   cap := 'Audio / media library folder'; end;
    3: begin ed := edDirSfx;        cap := 'Sound effects folder'; end;
    4: begin ed := edDirExport;     cap := 'Export / render output folder'; end;
    5: begin ed := edDirRecordings; cap := 'Recordings folder'; end;
    6: begin ed := edDirTemp;       cap := 'Temporary files folder'; end;
    7: begin ed := edDirCache;      cap := 'Cache files folder'; end;
  end;
  if ed = nil then Exit;
  dir := ed.Text;
  {$IFDEF FPC}
  if SelectDirectory(cap, dir, dir) then
  {$ELSE}
  if SelectDirectory(cap, '', dir) then
  {$ENDIF}
    ed.Text := dir;
end;

{ ============================ Browser tab (Phase 33) ==============

  A lazily-populated file-system tree (roots: the Settings tab's Audio
  Library and SFX folders, plus whatever the user adds via "Add folder...")
  feeding drag-and-drop into the Timeline (audio files -> a new clip) and
  the Mixer (.dll -> a new VST insert on the strip under the drop point).
  This is in-app VCL/LCL dragging (TTreeView.BeginDrag / OnDragOver /
  OnDragDrop) - not OS Explorer drag-and-drop, which would need a much
  heavier IDropTarget/OleInitialize integration; dragging FROM this tree
  INTO pbTimeline/pbMixer covers the actual ask ("drag a sample onto the
  timeline") without that extra machinery.

  Every tree node tags itself via TTreeNode.Data with one of the BRND_*
  markers below - no heap-allocated per-node strings to manage. A node's
  full filesystem path is never stored; it is rebuilt on demand by
  BrowserNodePath, which walks the node's parent chain and joins their
  Text - safe because the tree's shape mirrors the filesystem exactly
  (root nodes hold an absolute path, every other node holds one path
  segment). }

const
  BRND_DIR: Pointer = Pointer(1);
  BRND_FILE: Pointer = Pointer(2);
  BRND_PLACEHOLDER: Pointer = Pointer(3);

function TfrmMain.BrowserIsAudioExt(const AExt: string): Boolean;
begin
  Result := (AExt = '.wav') or (AExt = '.flac') or (AExt = '.mp3') or
    (AExt = '.mp4') or (AExt = '.m4a');
end;

function TfrmMain.BrowserNodePath(ANode: TTreeNode): string;
var
  parts: TStringList;
  n: TTreeNode;
  i: Integer;
begin
  Result := '';
  if ANode = nil then Exit;
  parts := TStringList.Create;
  try
    n := ANode;
    while n <> nil do
    begin
      parts.Insert(0, n.Text);
      n := n.Parent;
    end;
    Result := parts[0];   // root node's Text is already an absolute path
    for i := 1 to parts.Count - 1 do
      Result := IncludeTrailingPathDelimiter(Result) + parts[i];
  finally
    parts.Free;
  end;
end;

procedure TfrmMain.BrowserAddRoot(const APath: string);
var
  root: TTreeNode;
  i: Integer;
begin
  if (Trim(APath) = '') or not DirectoryExists(APath) then Exit;
  for i := 0 to tvBrowser.Items.Count - 1 do
    if (tvBrowser.Items[i].Parent = nil) and
       SameText(tvBrowser.Items[i].Text, APath) then
      Exit;   // already a root
  root := tvBrowser.Items.AddChild(nil, APath);
  root.Data := BRND_DIR;
  tvBrowser.Items.AddChild(root, '(loading...)').Data := BRND_PLACEHOLDER;
end;

{ Roots come from the Settings tab's configured folders (edDirAudioLib /
  edDirSfx - loaded from CFG_PATH_AUDIO_LIB/CFG_PATH_SFX by LoadSettingsTab,
  which FormCreate always calls before this) so the Browser tracks whatever
  the user has already told UDAW its sample/SFX libraries are, instead of a
  second, disconnected copy of that configuration. Safe to call repeatedly -
  BrowserAddRoot skips a path that is already a root. }
procedure TfrmMain.PopulateBrowserRoots;
begin
  BrowserAddRoot(edDirAudioLib.Text);
  BrowserAddRoot(edDirSfx.Text);
  { first-run fallback when Settings has neither folder configured yet -
    BrowserAddRoot is a no-op for a path that doesn't exist or is already a
    root, so this never duplicates the two lines above }
  if tvBrowser.Items.Count = 0 then
  begin
    BrowserAddRoot('G:\Studio\mine');
    BrowserAddRoot('G:\Studio\SFX');
  end;
end;

{ The AI tools unit (UDAW.AI.ToolCommands) has no UI dependency, so it cannot
  read tvBrowser itself; this is the callback MainForm wires onto
  TAIToolDispatcher.OnGetBrowserRoots (mirrors OnGetDoc/OnGetCommands in
  UDAW.AI.MCPServer.TUDAWMcpServer) so the AI's FindSample/AddSampleToTimeline
  tools see exactly the same root folders as the Browser tab - same
  enumeration tvBrowser's own root nodes as btnBrowserRefreshClick. }
function TfrmMain.GetAiBrowserRoots: TArray<string>;
var
  roots: TStringList;
  i: Integer;
begin
  roots := TStringList.Create;
  try
    for i := 0 to tvBrowser.Items.Count - 1 do
      if tvBrowser.Items[i].Parent = nil then
        roots.Add(tvBrowser.Items[i].Text);
    Result := roots.ToStringArray;
  finally
    roots.Free;
  end;
end;

procedure TfrmMain.BrowserExpandNode(ANode: TTreeNode);
var
  path, ext: string;
  sr: TSearchRec;
  child: TTreeNode;
begin
  if (ANode = nil) or (ANode.Data <> BRND_DIR) then Exit;
  if not ((ANode.Count = 1) and (ANode.Item[0].Data = BRND_PLACEHOLDER)) then
    Exit;   // already populated (or found genuinely empty last time)
  ANode.Item[0].Delete;

  path := BrowserNodePath(ANode);

  { subdirectories first }
  if FindFirst(IncludeTrailingPathDelimiter(path) + '*', faDirectory, sr) = 0 then
  begin
    try
      repeat
        if (sr.Attr and faDirectory <> 0) and (sr.Name <> '.') and (sr.Name <> '..') then
        begin
          child := tvBrowser.Items.AddChild(ANode, sr.Name);
          child.Data := BRND_DIR;
          tvBrowser.Items.AddChild(child, '(loading...)').Data := BRND_PLACEHOLDER;
        end;
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
  end;

  { then files with a format the Timeline or Mixer can actually use }
  if FindFirst(IncludeTrailingPathDelimiter(path) + '*', faAnyFile, sr) = 0 then
  begin
    try
      repeat
        if (sr.Attr and faDirectory = 0) then
        begin
          ext := LowerCase(ExtractFileExt(sr.Name));
          if BrowserIsAudioExt(ext) or (ext = '.dll') then
          begin
            child := tvBrowser.Items.AddChild(ANode, sr.Name);
            child.Data := BRND_FILE;
          end;
        end;
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
  end;

  if ANode.Count = 0 then
    tvBrowser.Items.AddChild(ANode, '(empty)').Data := nil;
end;

procedure TfrmMain.tvBrowserExpanding(Sender: TObject; Node: TTreeNode;
  var AllowExpansion: Boolean);
begin
  BrowserExpandNode(Node);
  AllowExpansion := True;
end;

{ Left-click-and-hold on a FILE node (never a folder) starts an in-app VCL
  drag; BeginDrag(False) means the drag only actually starts once the mouse
  moves past the drag threshold, so a plain click still just selects. }
procedure TfrmMain.tvBrowserMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  node: TTreeNode;
begin
  if Button <> mbLeft then Exit;
  node := tvBrowser.GetNodeAt(X, Y);
  if (node = nil) or (node.Data <> BRND_FILE) then Exit;
  node.Selected := True;
  tvBrowser.BeginDrag(False);
end;

procedure TfrmMain.btnBrowserAddFolderClick(Sender: TObject);
var
  dir: string;
begin
  dir := '';
  {$IFDEF FPC}
  if SelectDirectory('Add a folder to the Browser', dir, dir) then
  {$ELSE}
  if SelectDirectory('Add a folder to the Browser', '', dir) then
  {$ENDIF}
  begin
    ShowStatusProgress('Adding browser folder...', 100);
    try
      UpdateStatusProgress(25, 'Checking selected folder...');
      BrowserAddRoot(dir);
      UpdateStatusProgress(100, 'Browser folder ready: ' + dir);
      memBrowser.Lines.Insert(0, 'added browser folder: ' + dir);
    finally
      HideStatusProgress;
    end;
  end;
end;

{ Full rescan: every root's Text (its absolute path) survives being cleared
  and re-added, so this just throws away all cached listings and rebuilds
  the roots from scratch - picks up files added on disk since the tab was
  last opened. }
procedure TfrmMain.btnBrowserRefreshClick(Sender: TObject);
var
  roots: TStringList;
  i: Integer;
begin
  ShowStatusProgress('Refreshing Browser...', 100);
  roots := TStringList.Create;
  try
    UpdateStatusProgress(10, 'Collecting browser folders...');
    for i := 0 to tvBrowser.Items.Count - 1 do
      if tvBrowser.Items[i].Parent = nil then
        roots.Add(tvBrowser.Items[i].Text);
    tvBrowser.Items.Clear;
    for i := 0 to roots.Count - 1 do
    begin
      BrowserAddRoot(roots[i]);
      UpdateStatusProgress(20 + Round((i + 1) * 80 / Max(1, roots.Count)),
        Format('Refreshing Browser folder %d of %d...', [i + 1, roots.Count]));
    end;
    memBrowser.Lines.Insert(0, Format('refreshed %d browser folder(s)', [roots.Count]));
  finally
    roots.Free;
    HideStatusProgress;
  end;
end;

{ Accessibility path for importing without dragging.  A Timeline audio lane
  selected by clicking it is used as the destination; otherwise a new lane is
  created.  Placement is always the snapped playhead, so the Browser button
  is deterministic and matches an explicit Timeline drop. }
procedure TfrmMain.btnBrowserImportClick(Sender: TObject);
var
  path: string;
  trackId: Integer;
begin
  if (tvBrowser.Selected = nil) or (tvBrowser.Selected.Data <> BRND_FILE) then
  begin
    memBrowser.Lines.Insert(0, 'select a file in the tree first');
    Exit;
  end;
  path := BrowserNodePath(tvBrowser.Selected);
  if not BrowserIsAudioExt(LowerCase(ExtractFileExt(path))) then
  begin
    memBrowser.Lines.Insert(0, 'not an importable audio format: ' + path);
    Exit;
  end;
  if FProject = nil then Exit;
  trackId := TlSelectedAudioTrackId;
  if trackId < 0 then trackId := TlNewAudioTrackId;
  if ImportBrowserFileToTimeline(path, trackId, FProject.Timeline.PlayheadSeconds) then
    memBrowser.Lines.Insert(0, 'imported onto Timeline track at playhead: ' + path)
  else
    memBrowser.Lines.Insert(0, 'import FAILED: ' + path);
end;

procedure TfrmMain.btnBrowserAddToSelectedClick(Sender: TObject);
begin
  { Kept as a clearly named entry point for mouse and keyboard users.  The
    Import button has the same destination semantics, while this caption makes
    the selected-channel behaviour discoverable in the Browser itself. }
  btnBrowserImportClick(Sender);
end;

{ Shared by the drag-drop targets and btnBrowserImportClick. Dispatches on
  extension to whichever importer the Timeline tab's own menu commands
  already use (TAddTimelineClipCommand for WAV, since there is no dedicated
  TImportWavCommand; TImportFlacCommand/TImportMp3Command/TImportMp4Command
  otherwise) - the same undo-safe non-destructive clip either way. }
function TfrmMain.ImportBrowserFileToTimeline(const APath: string; ATrackId: Integer;
  AStartSeconds: Double): Boolean;
var
  ext: string;
  info: TWavInfo;
  src: TMediaSource;
  addCmd: TAddTimelineClipCommand;
  flacCmd: TImportFlacCommand;
  mp3Cmd: TImportMp3Command;
  mp4Cmd: TImportMp4Command;
begin
  Result := False;
  if FProject = nil then Exit;
  ext := LowerCase(ExtractFileExt(APath));
  ShowStatusProgress('Importing ' + ExtractFileName(APath) + '...', 100);
  try
    try
      UpdateStatusProgress(5, 'Validating ' + ExtractFileName(APath) + '...');
      if ext = '.wav' then
    begin
      if not FileLooksLikeWav(APath) then Exit;
      info := ReadWavInfo(APath);
      src := FProject.Timeline.AddSource(APath, info.SampleRate, info.Channels, info.FrameCount);
      addCmd := TAddTimelineClipCommand.Create(FProject, ATrackId, src.Id,
        ExtractFileName(APath), AStartSeconds, 0, info.FrameCount / info.SampleRate);
      FCmds.Perform(addCmd);
      FTlSelClipId := addCmd.CreatedId;
      UpdateStatusProgress(30, 'Adding clip to Timeline...');
      WarmClipWaveform(src.Id, 30, 70, False);
    end
      else if ext = '.flac' then
    begin
      if not FlacSniffFile(APath) then Exit;
      flacCmd := TImportFlacCommand.Create(FProject, ATrackId, APath, AStartSeconds, 0);
      FCmds.Perform(flacCmd);
      FTlSelClipId := flacCmd.CreatedClipId;
      UpdateStatusProgress(30, 'Adding FLAC clip to Timeline...');
      WarmClipWaveform(flacCmd.SourceId, 30, 70, False);
    end
      else if ext = '.mp3' then
    begin
      if not Mp3SniffFile(APath) then Exit;
      mp3Cmd := TImportMp3Command.Create(FProject, ATrackId, APath, AStartSeconds, 0);
      FCmds.Perform(mp3Cmd);
      FTlSelClipId := mp3Cmd.CreatedClipId;
      UpdateStatusProgress(30, 'Adding MP3 clip to Timeline...');
      WarmClipWaveform(mp3Cmd.SourceId, 30, 70, False);
    end
      else if (ext = '.mp4') or (ext = '.m4a') then
    begin
      if not Mp4SniffFile(APath) then Exit;
      mp4Cmd := TImportMp4Command.Create(FProject, ATrackId, APath, AStartSeconds, 0);
      FCmds.Perform(mp4Cmd);
      FTlSelClipId := mp4Cmd.CreatedClipId;
      UpdateStatusProgress(30, 'Adding MP4/AAC clip to Timeline...');
      WarmClipWaveform(mp4Cmd.SourceId, 30, 70, False);
    end
      else
        Exit;
      UpdateStatusProgress(100, 'Import complete: ' + ExtractFileName(APath));
      Result := True;
      ApplyBaselineTempoOnImport(FTlSelClipId);
      RefreshTimelineTab;
    except
      on E: Exception do
        memTimeline.Lines.Insert(0, 'Drag-drop import FAILED: ' + E.Message);
    end;
  finally
    HideStatusProgress;
  end;
end;

procedure TfrmMain.pbTimelineDragOver(Sender, Source: TObject; X, Y: Integer;
  State: TDragState; var Accept: Boolean);
begin
  Accept := (Source = tvBrowser) and (FProject <> nil) and
    (tvBrowser.Selected <> nil) and (tvBrowser.Selected.Data = BRND_FILE) and
    BrowserIsAudioExt(LowerCase(ExtractFileExt(BrowserNodePath(tvBrowser.Selected))));
end;

{ Drops onto an existing audio track import onto that track at the dropped
  time; anywhere else (a non-audio track, or empty space below the last
  track) gets its own new audio track, same as the Timeline's Import menu
  items - dropping should never silently fail to find a place to land. }
procedure TfrmMain.pbTimelineDragDrop(Sender, Source: TObject; X, Y: Integer);
var
  path: string;
  trackId: Integer;
  sec: Double;
begin
  if (Source <> tvBrowser) or (tvBrowser.Selected = nil) or
     (tvBrowser.Selected.Data <> BRND_FILE) or (FProject = nil) then Exit;
  path := BrowserNodePath(tvBrowser.Selected);
  if not BrowserIsAudioExt(LowerCase(ExtractFileExt(path))) then Exit;

  FTlView.SetViewportWidth(pbTimeline.Width);
  sec := FTlView.Snap(FTlView.XToSeconds(X));
  if sec < 0 then sec := 0;

  trackId := TlDropTargetTrackId(X, Y);

  if ImportBrowserFileToTimeline(path, trackId, sec) then
    memBrowser.Lines.Insert(0, 'dropped onto Timeline: ' + path)
  else
    memBrowser.Lines.Insert(0, 'drop import FAILED: ' + path);
end;

{$IFNDEF FPC}
{ OS Explorer drag-in - DragAcceptFiles is registered on the FORM's handle in
  FormCreate, not pbTimeline's: pbTimeline is a TWheelPaintBox, i.e. a
  TPaintBox/TGraphicControl, which is windowless and has no HWND of its own
  to register. DragQueryPoint therefore returns a point in the FORM's client
  coordinates, which gets mapped into pbTimeline's own client space below (and
  ignored entirely if the drop landed outside pbTimeline, e.g. on another
  tab) before it plugs into the same FTlView/TlDropTargetTrackId math the
  in-app Browser-tree drop above uses. Every dropped file lands at the same
  snapped drop time; the first usable file uses TlDropTargetTrackId's normal
  "track under the drop, else the selected track, else a new one" rule, and
  any further files each get their own new audio track rather than
  overlapping the first clip on the same track. }
procedure TfrmMain.WMDropFiles(var Msg: TWMDropFiles);
var
  fileCount, i, len: Integer;
  fileName: string;
  dropPtForm, dropPt: TPoint;
  trackId: Integer;
  sec: Double;
  firstFile: Boolean;
begin
  try
    if FProject = nil then Exit;
    DragQueryPoint(Msg.Drop, dropPtForm);
    dropPt := pbTimeline.ScreenToClient(ClientToScreen(dropPtForm));
    if not PtInRect(pbTimeline.ClientRect, dropPt) then
    begin
      memBrowser.Lines.Insert(0, 'drop ignored (not over the Timeline)');
      Exit;
    end;
    FTlView.SetViewportWidth(pbTimeline.Width);
    sec := FTlView.Snap(FTlView.XToSeconds(dropPt.X));
    if sec < 0 then sec := 0;

    fileCount := DragQueryFile(Msg.Drop, $FFFFFFFF, nil, 0);
    firstFile := True;
    for i := 0 to fileCount - 1 do
    begin
      len := DragQueryFile(Msg.Drop, i, nil, 0);
      SetLength(fileName, len);
      DragQueryFile(Msg.Drop, i, PChar(fileName), len + 1);
      if not BrowserIsAudioExt(LowerCase(ExtractFileExt(fileName))) then
      begin
        memBrowser.Lines.Insert(0, 'skipped (not an importable audio format): ' + fileName);
        Continue;
      end;
      if firstFile then
      begin
        trackId := TlDropTargetTrackId(dropPt.X, dropPt.Y);
        firstFile := False;
      end
      else
        trackId := TlNewAudioTrackId;
      if ImportBrowserFileToTimeline(fileName, trackId, sec) then
        memBrowser.Lines.Insert(0, 'dropped from Explorer onto Timeline: ' + fileName)
      else
        memBrowser.Lines.Insert(0, 'Explorer drop import FAILED: ' + fileName);
    end;
  finally
    DragFinish(Msg.Drop);
    Msg.Result := 0;
  end;
end;
{$ENDIF}

procedure TfrmMain.pbMixerDragOver(Sender, Source: TObject; X, Y: Integer;
  State: TDragState; var Accept: Boolean);
begin
  Accept := (Source = tvBrowser) and (FProject <> nil) and
    (tvBrowser.Selected <> nil) and (tvBrowser.Selected.Data = BRND_FILE) and
    SameText(ExtractFileExt(BrowserNodePath(tvBrowser.Selected)), '.dll');
end;

{ Mirrors btnMixAddVSTClick's own load-probe-before-adding safety check: a
  DLL that doesn't scan as a usable VST2 effect is rejected here exactly the
  same way, rather than becoming a broken insert. }
procedure TfrmMain.pbMixerDragDrop(Sender, Source: TObject; X, Y: Integer);
var
  path, pathB64, loadError: string;
  i, targetStripId, paramCount: Integer;
  targetStrip: TMixStrip;
begin
  if (Source <> tvBrowser) or (tvBrowser.Selected = nil) or
     (tvBrowser.Selected.Data <> BRND_FILE) or (FProject = nil) then Exit;
  path := BrowserNodePath(tvBrowser.Selected);
  if not SameText(ExtractFileExt(path), '.dll') then Exit;

  targetStripId := -1;
  for i := 0 to High(FMixStripRects) do
    if PtInRect(FMixStripRects[i], Point(X, Y)) then
    begin
      targetStripId := FMixStripIds[i];
      Break;
    end;
  if targetStripId < 0 then
  begin
    memBrowser.Lines.Insert(0, 'drop a plugin directly on a mixer strip');
    Exit;
  end;

  pathB64 := TNetEncoding.Base64.EncodeBytesToString(TEncoding.UTF8.GetBytes(path));
  targetStrip := FProject.Mixer.StripById(targetStripId);
  if (targetStrip <> nil) and MixStripHasVst2Insert(targetStrip, pathB64) then
  begin
    memBrowser.Lines.Insert(0, 'already on that strip, ignored: ' + path);
    Exit;
  end;

  ShowStatusProgress('Adding VST2 plugin ' + ExtractFileName(path) + '...', 100);
  try
    UpdateStatusProgress(15, 'Probing VST2 plugin...');
    if not ProbeVst2File(path, paramCount, loadError) then
    begin
      memBrowser.Lines.Insert(0, 'not a usable VST2 plugin: ' + path + '  (' + loadError + ')');
      Exit;
    end;

    UpdateStatusProgress(70, 'Adding plugin insert to selected mixer strip...');
    FCmds.Perform(TAddMixInsertCommand.Create(FProject, targetStripId, 'vst2',
      Format('path=%s;state=;paramcount=%d', [pathB64, paramCount]), -1,
      ExtractFileName(path)));
    RefreshMixerTab;
    UpdateStatusProgress(100, 'Plugin insert ready: ' + ExtractFileName(path));
    memBrowser.Lines.Insert(0, 'dropped VST insert onto strip: ' + path);
  finally
    HideStatusProgress;
  end;
end;

initialization
  RegisterClass(TWheelPaintBox);

end.
