unit UDAW.Audio.Graph.Nodes;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 4 - Audio Graph: the processing nodes.

  A node has exactly one logical audio input (a summing point - the graph
  executor sums every inbound connection into it) and one output. Source and
  input nodes have no input. Every node is built from the Phase 3 DSP
  primitives - there is no placeholder processing here: the gain node ramps a
  real one-pole, the filter nodes are the RBJ / Butterworth designs, the delay
  node is a real fractional delay line, the meter node runs the BS.1770 chain.

  Nodes are RT-safe once Configure has sized their state: Process never
  allocates, locks or touches the disk. Configure / Reset run off the audio
  thread (see UDAW.Audio.Graph for the plan-swap protocol that makes edits
  safe). }

interface

uses
  SysUtils, Math, System.NetEncoding, System.JSON,
  UDAW.Errors,
  UDAW.Audio.Types, UDAW.Audio.Buffer, UDAW.Audio.Source,
  UDAW.DSP.Math, UDAW.DSP.Filters, UDAW.DSP.Meter, UDAW.DSP.Envelope,
  UDAW.DSP.Dynamics, UDAW.DSP.Modulation, UDAW.DSP.Distortion,
  UDAW.DSP.Reverb, UDAW.DSP.GraphicEQ,
  UDAW.DSP.MultibandComp, UDAW.DSP.Mastering, UDAW.DSP.Visualization,
  UDAW.DSP.ParametricEQ, UDAW.DSP.StereoWidth, UDAW.DSP.TransientShaper,
  UDAW.DSP.Exciter, UDAW.DSP.LookaheadLimiter, UDAW.DSP.PitchShift,
  UDAW.Mixer.VST2, UDAW.Mixer.CLAP, UDAW.Mixer.VST3, UDAW.Scripting.PyPlugin;

const
  GRAPH_SUBSYS = 'AudioGraph';

  DELAY_MAX_MS = 2000.0;   { delay-line ceiling; allocated once per node }

type
  TNodeKind = (
    nkInput,        // external input (capture / offline feed); no inbound
    nkSource,       // internal generator (wraps IAudioSource); no inbound
    nkGain,         // gain in dB, click-free
    nkPan,          // stereo pan / balance, constant-power
    nkBiquad,       // one RBJ biquad (parametric EQ / filter)
    nkFilterChain,  // Butterworth low/high-pass, order 2*pairs
    nkDCBlock,      // DC blocker
    nkDelay,        // delay line: time / feedback / wet-dry
    nkChannelMap,   // channel remap (swap L/R, mono sum, widen)
    nkMeter,        // analysis tap (peak / RMS / true-peak / LUFS), unity pass
    nkCompressor,   // dynamics: compressor / limiter / expander / gate / de-esser
    nkModulation,   // chorus / flanger / phaser / tremolo / auto-pan
    nkDistortion,   // saturation / hard-clip / foldback / bit-crusher
    nkReverb,       // internal algorithmic reverb
    nkGraphicEQ,    // fixed-band graphic equaliser
    nkMultibandComp,// Phase 19: 3-band multiband compressor/limiter
    nkMastering,    // Phase 19: mastering chain (multiband + width + true-peak limiter + loudness AGC)
    nkScope,        // Phase 18: analysis tap - spectrum / spectrogram / goniometer / oscilloscope / meters
    nkVST2,         // hosted VST2-ABI plugin DLL (UDAW.Mixer.VST2), audio-in/audio-out only
    nkParametricEQ, // Phase 34: multi-band fully parametric EQ (peaking/shelf/cut per band)
    nkStereoWidth,  // Phase 34: standalone mid/side stereo widener/imager
    nkTransientShaper, // Phase 34: attack/sustain envelope-differential shaper
    nkExciter,      // Phase 34: harmonic exciter / high-band saturation enhancer
    nkPitchShift,   // Phase 34: real-time-chunked wrapper around TPitchShifter
    nkLookaheadLimiter, // Phase 34: real lookahead brickwall limiter
    nkCLAP,         // hosted CLAP plugin (UDAW.Mixer.CLAP), audio effect
    nkVST3,         // hosted VST3 plugin (UDAW.Mixer.VST3), audio effect
    nkPython,       // user Python plug-in (UDAW.Scripting.PyPlugin), audio effect
    nkBus,          // explicit summing / routing point (unity pass)
    nkOutput        // graph output / master; exactly one per graph
  );

  TChannelMapMode = (cmPassthru, cmSwapLR, cmMonoSum, cmWiden);

  { ---- base ---- }

  TAudioNode = class
  private
    FId: Integer;
    FName: string;
    FKind: TNodeKind;
    FBypass: Boolean;
    FMute: Boolean;
  protected
    FSampleRate: Integer;
    FMaxFrames: Integer;
    FChannels: Integer;
    FConfigured: Boolean;
  public
    constructor Create(AId: Integer; AKind: TNodeKind; const AName: string);

    { (Re)size runtime state. Idempotent: a call with unchanged geometry only
      recomputes coefficients, it does not reallocate. Off the RT thread. }
    procedure Configure(ASampleRate, AMaxFrames, AChannels: Integer);
    { Clear runtime state (filter memory, delay line, meter ballistics). }
    procedure Reset; virtual;

    { RT: read AIn[0..FrameCount), write AOut[0..FrameCount). AIn is always a
      valid buffer (the executor hands over a cleared one when nothing is
      connected). Never called when the node is muted or bypassed. }
    procedure Process(AIn, AOut: TAudioBuffer); virtual; abstract;

    { Optional external sidechain / detector key for the block that follows.
      Only dynamics nodes use it; the default is a no-op. Pass nil to clear. }
    procedure SetSidechain(ABuffer: TAudioBuffer); virtual;

    function AcceptsInput: Boolean; virtual;
    function SupportsChannels(ACount: Integer): Boolean; virtual;

    { key=value;key=value - used by the serializer and the UI. Kind, id and
      name are written by the serializer itself. }
    function SerializeParams: string; virtual;
    procedure DeserializeParams(const AText: string); virtual;

    property Id: Integer read FId;
    property Kind: TNodeKind read FKind;
    property Name: string read FName write FName;
    property Bypass: Boolean read FBypass write FBypass;
    property Mute: Boolean read FMute write FMute;
    property SampleRate: Integer read FSampleRate;
    property Channels: Integer read FChannels;
  protected
    procedure DoConfigure; virtual;   // subclass allocation / coeff recalc
  end;

  { ---- generators ---- }

  TGraphSourceNode = class(TAudioNode)
  private
    FShape: TOscShape;
    FFreq: Double;
    FAmp: Single;
    FSource: IAudioSource;
    procedure Rebuild;
  public
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function AcceptsInput: Boolean; override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
    procedure SetTone(AShape: TOscShape; AFreqHz: Double; AAmplitude: Single);
    property Shape: TOscShape read FShape;
    property Freq: Double read FFreq;
    property Amp: Single read FAmp;
  protected
    procedure DoConfigure; override;
  end;

  TInputNode = class(TAudioNode)
  public
    procedure Process(AIn, AOut: TAudioBuffer); override;   // pass the fed input
    function AcceptsInput: Boolean; override;
  end;

  { ---- gain / pan ---- }

  TGainNode = class(TAudioNode)
  private
    FGainDb: Double;
    FCurLin: Double;
  public
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
    property GainDb: Double read FGainDb write FGainDb;
  protected
    procedure DoConfigure; override;
  end;

  TPanNode = class(TAudioNode)
  private
    FPos: Double;                 // -1..+1
    FCurL, FCurR: Double;
  public
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
    property Pos: Double read FPos write FPos;
  protected
    procedure DoConfigure; override;
  end;

  { ---- filters ---- }

  TBiquadNode = class(TAudioNode)
  private
    FKindBq: TBiquadKind;
    FFreq, FQ, FGainDb: Double;
    FBiq: array of TBiquad;
  public
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
    procedure SetFilter(AKind: TBiquadKind; AFreqHz, AQ, AGainDb: Double);
    property FilterKind: TBiquadKind read FKindBq;
    property Freq: Double read FFreq;
    property Q: Double read FQ;
  protected
    procedure DoConfigure; override;
  end;

  TFilterChainMode = (fcLowpass, fcHighpass);

  TFilterChainNode = class(TAudioNode)
  private
    FMode: TFilterChainMode;
    FFreq: Double;
    FPairs: Integer;             // biquad stages => order 2*FPairs
    FChain: array of TBiquadChain;
    procedure FreeChains;
  public
    destructor Destroy; override;
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
    property Mode: TFilterChainMode read FMode;
    property Freq: Double read FFreq;
  protected
    procedure DoConfigure; override;
  end;

  TDCBlockNode = class(TAudioNode)
  private
    FCornerHz: Double;
    FDC: array of TDCBlocker;
  public
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
  protected
    procedure DoConfigure; override;
  end;

  { ---- delay ---- }

  TDelayNode = class(TAudioNode)
  private
    FTimeMs: Double;
    FFeedback: Double;           // 0..0.95
    FMix: Double;                // 0..1 wet
    FPingPong: Boolean;          // cross-channel feedback (stereo bounce)
    FSyncBpm: Double;            // 0 = manual FTimeMs; > 0 = tempo-synced
    FSyncBeats: Double;          // repeat time in quarter-note beats
    FLine: array of array of Single;   // [channel][ringpos]
    FLen: Integer;
    FWrite: Integer;
    function EffectiveTimeMs: Double;
  public
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
    property TimeMs: Double read FTimeMs write FTimeMs;
    property Feedback: Double read FFeedback write FFeedback;
    property Mix: Double read FMix write FMix;
    property PingPong: Boolean read FPingPong write FPingPong;
  protected
    procedure DoConfigure; override;
  end;

  { ---- channel map ---- }

  TChannelMapNode = class(TAudioNode)
  private
    FMode: TChannelMapMode;
    FWidth: Double;              // for cmWiden: 0 = mono .. 1 = as-is .. 2 = extra wide
  public
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SupportsChannels(ACount: Integer): Boolean; override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
    property Mode: TChannelMapMode read FMode write FMode;
  end;

  { ---- meter tap ---- }

  TMeterNode = class(TAudioNode)
  private
    FPeak: TPeakMeter;
    FRms: TRmsMeter;
    FTruePeak: TTruePeakMeter;
    FLoud: TLoudnessMeter;
    { published for the UI - written by the RT thread, read by the UI thread;
      plain scalar reads are atomic on every architecture UDAW targets and a
      torn value on a moving meter is harmless. }
    FPeakDb: Double;
    FRmsDb: Double;
    FTruePeakDb: Double;
    FMomentaryLufs: Double;
    FIntegratedLufs: Double;
  public
    destructor Destroy; override;
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    property PeakDb: Double read FPeakDb;
    property RmsDb: Double read FRmsDb;
    property TruePeakDb: Double read FTruePeakDb;
    property MomentaryLufs: Double read FMomentaryLufs;
    property IntegratedLufs: Double read FIntegratedLufs;
  protected
    procedure DoConfigure; override;
  end;

  { ---- Phase 18 analysis tap ---- }

  TScopeNode = class(TAudioNode)
  private
    FSpectrum: TSpectrumAnalyzer;
    FGonio: TGoniometer;
    FScope: TOscilloscopeCapture;
    FBallistics: array of TBallisticMeter;
    FPreset: TMeterBallistics;
    FMonoScratch: array of Single;
  public
    destructor Destroy; override;
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;

    procedure GetSpectrumDb(var ADb: array of Double);
    procedure GetSpectrumPeakDb(var ADb: array of Double);
    function SpectrumBins: Integer;
    procedure GetOscilloscopeSnapshot(var ABuf: array of Single; out ACount: Integer);
    function Correlation: Double;
    function WidthEstimate: Double;
    function BallisticReadingDb(AChannel: Integer): Double;
    function BallisticReadingScale01(AChannel: Integer): Double;

    property Spectrum: TSpectrumAnalyzer read FSpectrum;
    property Gonio: TGoniometer read FGonio;
    property Scope: TOscilloscopeCapture read FScope;
    property Preset: TMeterBallistics read FPreset;
  protected
    procedure DoConfigure; override;
  end;

  { ---- Phase 10 effects ---- }

  TEffectNodeBase = class(TAudioNode)
  protected
    FInPtrs: array of PSingle;
    FOutPtrs: array of PSingle;
    procedure GatherPtrs(AIn, AOut: TAudioBuffer; out ANC: Integer);
  end;

  TCompressorNode = class(TEffectNodeBase)
  private
    FProc: TDynamicsProcessor;
    FMode: TDynamicsMode;
    FThresh, FRatio, FKnee, FAttack, FRelease, FMakeup, FHold, FRange, FScFreq: Double;
    FSc: TAudioBuffer;                 // external sidechain (not owned)
    FScPtrs: array of PSingle;
  public
    destructor Destroy; override;
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    procedure SetSidechain(ABuffer: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
    function GainReductionDb: Double;
  protected
    procedure DoConfigure; override;
  end;

  TModulationNode = class(TEffectNodeBase)
  private
    FProc: TModulationProcessor;
    FEffect: TModEffect;
    FRate, FDepth, FMix, FFeedback, FStereo: Double;
    FStages: Integer;
  public
    destructor Destroy; override;
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
  protected
    procedure DoConfigure; override;
  end;

  TDistortionNode = class(TEffectNodeBase)
  private
    FProc: TDistortionProcessor;
    FMode: TDistMode;
    FDrive, FTrimDb, FMix, FBits: Double;
    FDown, FOs: Integer;
  public
    destructor Destroy; override;
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
  protected
    procedure DoConfigure; override;
  end;

  TReverbNode = class(TEffectNodeBase)
  private
    FProc: TAlgoReverb;
    FSize, FDamp, FWidth, FMix, FPreDelay, FEarly, FTail: Double;
  public
    destructor Destroy; override;
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
  protected
    procedure DoConfigure; override;
  end;

  TGraphicEQNode = class(TEffectNodeBase)
  private
    FProc: TGraphicEQ;
    FBands: Integer;
    FGains: array of Double;
  public
    destructor Destroy; override;
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
    { re-reads only the band gains of a "bands=N;gains=..." text while the node is running;
      the band count is left alone, so nothing is reallocated }
    procedure ApplyGainsLive(const AText: string);
  protected
    procedure DoConfigure; override;
  end;

  { ---- Phase 19 advanced dynamics ---- }

  TMultibandCompNode = class(TEffectNodeBase)
  private
    FProc: TMultibandCompressor;
    FLowMidHz, FMidHighHz: Double;
    FThresh, FRatio, FKnee, FAttack, FRelease, FMakeup: array[0..2] of Double;
  public
    destructor Destroy; override;
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
    function BandGainReductionDb(ABand: Integer): Double;
  protected
    procedure DoConfigure; override;
  end;

  TMasteringNode = class(TEffectNodeBase)
  private
    FProc: TMasteringChain;
    FCeilingDb, FTargetLufs, FWidth: Double;
  public
    destructor Destroy; override;
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
    function CurrentTruePeakDb: Double;
    function CurrentIntegratedLufs: Double;
  protected
    procedure DoConfigure; override;
  end;

  { ---- Phase 34 - new effect suite ---- }

  TParametricEQNode = class(TEffectNodeBase)
  private
    FProc: TParametricEQ;
    FBandType: array[0..PEQ_BAND_COUNT - 1] of TPEQBandType;
    FBandFreq, FBandGain, FBandQ: array[0..PEQ_BAND_COUNT - 1] of Double;
  public
    destructor Destroy; override;
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
  protected
    procedure DoConfigure; override;
  end;

  TStereoWidthNode = class(TEffectNodeBase)
  private
    FProc: TStereoWidthProcessor;
    FWidth: Double;
  public
    destructor Destroy; override;
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
  protected
    procedure DoConfigure; override;
  end;

  TTransientShaperNode = class(TEffectNodeBase)
  private
    FProc: TTransientShaper;
    FAttackDb, FSustainDb: Double;
  public
    destructor Destroy; override;
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
  protected
    procedure DoConfigure; override;
  end;

  TExciterNode = class(TEffectNodeBase)
  private
    FProc: TExciter;
    FFreqHz, FDrive, FMix: Double;
    FOs: Integer;
  public
    destructor Destroy; override;
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
  protected
    procedure DoConfigure; override;
  end;

  TLookaheadLimiterNode = class(TEffectNodeBase)
  private
    FProc: TLookaheadLimiter;
    FCeilingDb, FReleaseMs, FLookaheadMs: Double;
  public
    destructor Destroy; override;
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
    function GainReductionDb: Double;
  protected
    procedure DoConfigure; override;
  end;

  { Thin real-time wrapper around the offline TPitchShifter (phase-vocoder
    stretch + resample). The underlying primitive works on a whole array at
    once and is not streaming-capable, so this node accumulates CHUNK-sized
    overlapping windows of input, calls it per HOP-sized hop, and reconstructs
    a continuous output stream by overlap-add through a Hann crossfade. This
    unavoidably introduces CHUNK-HOP worth of latency (a startup silence)
    before the first shifted audio appears - there is no way to make a
    phase-vocoder-based shifter latency-free without a different algorithm. }
  TPitchShiftNode = class(TEffectNodeBase)
  private
    FShifter: TPitchShifter;
    FSemitones: Double;
    FInWin: array of array of Single;     // [channel][CHUNK] sliding analysis window
    FInFill: array of Integer;            // new samples accumulated toward next HOP
    FOlaBuf: array of array of Single;    // [channel][CHUNK] overlap-add scratch
    FRing: array of array of Single;      // [channel][RingLen] output FIFO
    FRingLen: Integer;
    FRingRead: array of Integer;
    FRingWrite: array of Integer;
    FRingCount: array of Integer;
    FWindow: array of Single;             // Hann window, CHUNK long
    procedure EnsureAlloc;
    procedure RunHop(AChannel: Integer);
  public
    destructor Destroy; override;
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
  protected
    procedure DoConfigure; override;
  end;

  { ---- Phase (VST2 hosting) - hosted plugin insert ---- }

  { Wraps a UDAW.Mixer.VST2.TVST2Host as an insert-chain node. Params carry
    the plugin's DLL path and its saved state, both base64-encoded so an
    arbitrary path/binary state survives the mixer's "key=value;..." text
    format untouched. Loading is deferred to DoConfigure (i.e. to whenever
    the graph is prepared, off the RT thread, same as every other node's
    allocation) rather than to DeserializeParams, so a project can be loaded
    even while the referenced plugin DLL is temporarily missing - the insert
    just passes audio through dry and LoadError explains why. }
  TVST2Node = class(TEffectNodeBase)
  private
    FHost: TVST2Host;
    FPathB64: string;
    FStateB64: string;
    FLoadError: string;
    FPendingStateApplied: Boolean;
  public
    destructor Destroy; override;
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
    { The path as given to LoadOnly/LoadAndOpen (decoded from FPathB64). }
    function PluginPath: string;
    { Call after changing parameters/state from a plugin editor UI so the
      new state is what gets persisted (SerializeParams reads FStateB64,
      not the live plugin, to avoid round-tripping through the plugin on
      every save). }
    procedure CaptureState;
    property Host: TVST2Host read FHost;
    property LoadError: string read FLoadError;
  protected
    procedure DoConfigure; override;
  end;

  TCLAPNode = class(TEffectNodeBase)
  private
    FHost: TCLAPHost;
    FPathB64: string;
    FStateB64: string;
    FLoadError: string;
    FPendingStateApplied: Boolean;
  public
    destructor Destroy; override;
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
    { The path as given to LoadOnly/LoadAndOpen (decoded from FPathB64). }
    function PluginPath: string;
    { Call after changing parameters/state from a plugin editor UI so the
      new state is what gets persisted (SerializeParams reads FStateB64,
      not the live plugin, to avoid round-tripping through the plugin on
      every save). }
    procedure CaptureState;
    property Host: TCLAPHost read FHost;
    property LoadError: string read FLoadError;
  protected
    procedure DoConfigure; override;
  end;

  TVST3Node = class(TEffectNodeBase)
  private
    FHost: TVST3Host;
    FPathB64: string;
    FStateB64: string;
    FLoadError: string;
    FPendingStateApplied: Boolean;
  public
    destructor Destroy; override;
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
    { The path as given to LoadOnly/LoadAndOpen (decoded from FPathB64). }
    function PluginPath: string;
    { Call after changing parameters/state from a plugin editor UI so the
      new state is what gets persisted (SerializeParams reads FStateB64,
      not the live plugin, to avoid round-tripping through the plugin on
      every save). }
    procedure CaptureState;
    property Host: TVST3Host read FHost;
    property LoadError: string read FLoadError;
  protected
    procedure DoConfigure; override;
  end;

  { ---- Python plug-in insert ----

    Params (all values base64 so the "key=value;..." text survives any content):
      path   full path of the plug-in's script file: the insert points at it (the text is read when the
             plug-in starts, so editing the file changes the insert); src= is only read from old projects
      vals   JSON object of parameter id -> value, the settings saved with the project
      state  the script's own saved data (JSON)
      iid    instance id: lets an open editor window attach to the instance that is playing
      file   the file name it came from (display only)
      pn     the parameter names, one per line (the mixer's automation list)
    The script runs in its own Python process (see UDAW.Scripting.PyPlugin); if it cannot start
    the insert passes the audio through dry and LoadError says why. }
  TPythonNode = class(TEffectNodeBase)
  private
    FHost: TPyPluginHost;
    FSrcB64, FPathB64, FValsB64, FStateB64, FIid, FFileB64, FNamesB64: string;
    FStartedKey, FFailedKey, FLoadError: string;
    function ConfigKey: string;
    procedure DropHost;
  public
    destructor Destroy; override;
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
    property Host: TPyPluginHost read FHost;
    property LoadError: string read FLoadError;
    property InstanceId: string read FIid;
  protected
    procedure DoConfigure; override;
  end;

  { ---- bus / output ---- }

  TBusNode = class(TAudioNode)
  public
    procedure Process(AIn, AOut: TAudioBuffer); override;
  end;

  TOutputNode = class(TAudioNode)
  private
    FGainDb: Double;
    FCurLin: Double;
  public
    procedure Reset; override;
    procedure Process(AIn, AOut: TAudioBuffer); override;
    function SerializeParams: string; override;
    procedure DeserializeParams(const AText: string); override;
    property GainDb: Double read FGainDb write FGainDb;
  protected
    procedure DoConfigure; override;
  end;

{ ---- factory + name maps ---- }

function CreateNode(AId: Integer; AKind: TNodeKind; const AName: string): TAudioNode;
function NodeKindId(AKind: TNodeKind): string;
function NodeKindFromId(const AId: string; out AKind: TNodeKind): Boolean;
function NodeKindDisplay(AKind: TNodeKind): string;

function BiquadKindId(AKind: TBiquadKind): string;
function BiquadKindFromId(const AId: string; out AKind: TBiquadKind): Boolean;
function OscShapeId(AShape: TOscShape): string;
function OscShapeFromId(const AId: string; out AShape: TOscShape): Boolean;

{ Minimal "key=value;key=value" reader used by DeserializeParams. }
function ParamStrDef(const AText, AKey, ADefault: string): string;
function ParamFloat(const AText, AKey: string; ADefault: Double): Double;
function ParamInt(const AText, AKey: string; ADefault: Integer): Integer;
function ParamBool(const AText, AKey: string; ADefault: Boolean): Boolean;

implementation


uses
  UDAW.DSP.MathTables;

{ ================= small parsers ================= }

function SplitPairs(const AText: string): TArray<string>;
var
  parts: TArray<string>;
begin
  parts := AText.Split([';']);
  Result := parts;
end;

function ParamStrDef(const AText, AKey, ADefault: string): string;
var
  pair, k: string;
  eq: Integer;
begin
  for pair in SplitPairs(AText) do
  begin
    eq := Pos('=', pair);
    if eq <= 0 then Continue;
    k := Trim(Copy(pair, 1, eq - 1));
    if SameText(k, AKey) then
      Exit(Trim(Copy(pair, eq + 1, MaxInt)));
  end;
  Result := ADefault;
end;

function ParamFloat(const AText, AKey: string; ADefault: Double): Double;
var
  s: string;
  fs: TFormatSettings;
begin
  s := ParamStrDef(AText, AKey, '');
  if s = '' then Exit(ADefault);
  fs := TFormatSettings.Invariant;
  if not TryStrToFloat(s, Result, fs) then
    Result := ADefault;
end;

function ParamInt(const AText, AKey: string; ADefault: Integer): Integer;
var
  s: string;
begin
  s := ParamStrDef(AText, AKey, '');
  if (s = '') or not TryStrToInt(s, Result) then
    Result := ADefault;
end;

function ParamBool(const AText, AKey: string; ADefault: Boolean): Boolean;
var
  s: string;
begin
  s := LowerCase(ParamStrDef(AText, AKey, ''));
  if s = '' then Exit(ADefault);
  Result := (s = '1') or (s = 'true') or (s = 'yes') or (s = 'on');
end;

function FloatId(AValue: Double): string;
begin
  Result := FloatToStr(AValue, TFormatSettings.Invariant);
end;

{ ================= name maps ================= }

function NodeKindId(AKind: TNodeKind): string;
begin
  case AKind of
    nkInput:       Result := 'input';
    nkSource:      Result := 'source';
    nkGain:        Result := 'gain';
    nkPan:         Result := 'pan';
    nkBiquad:      Result := 'biquad';
    nkFilterChain: Result := 'filterchain';
    nkDCBlock:     Result := 'dcblock';
    nkDelay:       Result := 'delay';
    nkChannelMap:  Result := 'channelmap';
    nkMeter:       Result := 'meter';
    nkCompressor:  Result := 'compressor';
    nkModulation:  Result := 'modulation';
    nkDistortion:  Result := 'distortion';
    nkReverb:      Result := 'reverb';
    nkGraphicEQ:   Result := 'graphiceq';
    nkMultibandComp: Result := 'multibandcomp';
    nkMastering:   Result := 'mastering';
    nkScope:       Result := 'scope';
    nkVST2:        Result := 'vst2';
    nkCLAP:        Result := 'clap';
    nkVST3:        Result := 'vst3';
    nkPython:      Result := 'python';
    nkParametricEQ: Result := 'parametriceq';
    nkStereoWidth: Result := 'stereowidth';
    nkTransientShaper: Result := 'transientshaper';
    nkExciter:     Result := 'exciter';
    nkPitchShift:  Result := 'pitchshift';
    nkLookaheadLimiter: Result := 'lookaheadlimiter';
    nkBus:         Result := 'bus';
    nkOutput:      Result := 'output';
  else
    Result := '?';
  end;
end;

function NodeKindFromId(const AId: string; out AKind: TNodeKind): Boolean;
var
  k: TNodeKind;
begin
  for k := Low(TNodeKind) to High(TNodeKind) do
    if SameText(AId, NodeKindId(k)) then
    begin
      AKind := k;
      Exit(True);
    end;
  Result := False;
end;

function NodeKindDisplay(AKind: TNodeKind): string;
begin
  case AKind of
    nkInput:       Result := 'Input';
    nkSource:      Result := 'Source';
    nkGain:        Result := 'Gain';
    nkPan:         Result := 'Pan';
    nkBiquad:      Result := 'Biquad EQ';
    nkFilterChain: Result := 'Filter chain';
    nkDCBlock:     Result := 'DC blocker';
    nkDelay:       Result := 'Delay';
    nkChannelMap:  Result := 'Channel map';
    nkMeter:       Result := 'Meter';
    nkCompressor:  Result := 'Dynamics';
    nkModulation:  Result := 'Modulation';
    nkDistortion:  Result := 'Distortion';
    nkReverb:      Result := 'Reverb';
    nkGraphicEQ:   Result := 'Graphic EQ';
    nkMultibandComp: Result := 'Multiband Comp';
    nkMastering:   Result := 'Mastering';
    nkScope:       Result := 'Scope';
    nkVST2:        Result := 'VST Plugin';
    nkCLAP:        Result := 'CLAP Plugin';
    nkVST3:        Result := 'VST3 Plugin';
    nkPython:      Result := 'Python Plug-in';
    nkParametricEQ: Result := 'Parametric EQ';
    nkStereoWidth: Result := 'Stereo Width';
    nkTransientShaper: Result := 'Transient Shaper';
    nkExciter:     Result := 'Exciter';
    nkPitchShift:  Result := 'Pitch Shift';
    nkLookaheadLimiter: Result := 'Lookahead Limiter';
    nkBus:         Result := 'Bus';
    nkOutput:      Result := 'Output';
  else
    Result := '?';
  end;
end;

function BiquadKindId(AKind: TBiquadKind): string;
begin
  case AKind of
    bqLowpass:        Result := 'lowpass';
    bqHighpass:       Result := 'highpass';
    bqBandpassSkirt:  Result := 'bpskirt';
    bqBandpassPeak:   Result := 'bppeak';
    bqNotch:          Result := 'notch';
    bqAllpass:        Result := 'allpass';
    bqPeaking:        Result := 'peaking';
    bqLowShelf:       Result := 'lowshelf';
    bqHighShelf:      Result := 'highshelf';
  else
    Result := 'lowpass';
  end;
end;

function BiquadKindFromId(const AId: string; out AKind: TBiquadKind): Boolean;
var
  k: TBiquadKind;
begin
  for k := Low(TBiquadKind) to High(TBiquadKind) do
    if SameText(AId, BiquadKindId(k)) then
    begin
      AKind := k;
      Exit(True);
    end;
  Result := False;
end;

function OscShapeId(AShape: TOscShape): string;
begin
  case AShape of
    osSine:       Result := 'sine';
    osTriangle:   Result := 'triangle';
    osSaw:        Result := 'saw';
    osSquare:     Result := 'square';
    osWhiteNoise: Result := 'white';
    osPinkNoise:  Result := 'pink';
  else
    Result := 'sine';
  end;
end;

function OscShapeFromId(const AId: string; out AShape: TOscShape): Boolean;
var
  s: TOscShape;
begin
  for s := Low(TOscShape) to High(TOscShape) do
    if SameText(AId, OscShapeId(s)) then
    begin
      AShape := s;
      Exit(True);
    end;
  Result := False;
end;

{ ================= TAudioNode ================= }

constructor TAudioNode.Create(AId: Integer; AKind: TNodeKind; const AName: string);
begin
  inherited Create;
  FId := AId;
  FKind := AKind;
  if AName <> '' then
    FName := AName
  else
    FName := NodeKindDisplay(AKind);
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FMaxFrames := UDAW_DEFAULT_BUFFER_FRAMES;
  FChannels := 2;
end;

procedure TAudioNode.Configure(ASampleRate, AMaxFrames, AChannels: Integer);
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  if AMaxFrames > 0 then FMaxFrames := AMaxFrames;
  if AChannels > 0 then FChannels := AChannels;
  DoConfigure;
  FConfigured := True;
  Reset;
end;

procedure TAudioNode.DoConfigure;
begin
end;

procedure TAudioNode.Reset;
begin
end;

procedure TAudioNode.SetSidechain(ABuffer: TAudioBuffer);
begin
  { default: nodes that do not key off a sidechain ignore it }
end;

function TAudioNode.AcceptsInput: Boolean;
begin
  Result := True;
end;

function TAudioNode.SupportsChannels(ACount: Integer): Boolean;
begin
  Result := (ACount >= 1) and (ACount <= UDAW_MAX_CHANNELS);
end;

function TAudioNode.SerializeParams: string;
begin
  Result := '';
end;

procedure TAudioNode.DeserializeParams(const AText: string);
begin
end;

{ ================= TGraphSourceNode ================= }

procedure TGraphSourceNode.SetTone(AShape: TOscShape; AFreqHz: Double; AAmplitude: Single);
begin
  FShape := AShape;
  FFreq := AFreqHz;
  FAmp := AAmplitude;
  Rebuild;
end;

procedure TGraphSourceNode.Rebuild;
begin
  FSource := TToneSource.Create(FShape, FFreq, FAmp);
  if FConfigured then
    FSource.Prepare(FSampleRate, FMaxFrames, FChannels);
end;

procedure TGraphSourceNode.DoConfigure;
begin
  if FSource = nil then
    Rebuild
  else
    FSource.Prepare(FSampleRate, FMaxFrames, FChannels);
end;

procedure TGraphSourceNode.Reset;
begin
  if FSource <> nil then
    FSource.Reset;
end;

procedure TGraphSourceNode.Process(AIn, AOut: TAudioBuffer);
begin
  if FSource <> nil then
    FSource.Render(AOut)
  else
    AOut.Clear;
end;

function TGraphSourceNode.AcceptsInput: Boolean;
begin
  Result := False;
end;

function TGraphSourceNode.SerializeParams: string;
begin
  Result := Format('shape=%s;freq=%s;amp=%s',
    [OscShapeId(FShape), FloatId(FFreq), FloatId(FAmp)]);
end;

procedure TGraphSourceNode.DeserializeParams(const AText: string);
var
  sh: TOscShape;
begin
  if not OscShapeFromId(ParamStrDef(AText, 'shape', 'sine'), sh) then
    sh := osSine;
  FShape := sh;
  FFreq := ParamFloat(AText, 'freq', 440.0);
  FAmp := ParamFloat(AText, 'amp', 0.5);
  Rebuild;
end;

{ ================= TInputNode ================= }

procedure TInputNode.Process(AIn, AOut: TAudioBuffer);
begin
  { The executor feeds the graph's external-input buffer in as AIn for input
    nodes (or a cleared buffer when nothing is fed). }
  if AIn <> nil then
    AOut.CopyFrom(AIn)
  else
    AOut.Clear;
end;

function TInputNode.AcceptsInput: Boolean;
begin
  Result := False;
end;

{ ================= TGainNode ================= }

procedure TGainNode.DoConfigure;
begin
  FCurLin := DbToLinear(FGainDb);
end;

procedure TGainNode.Reset;
begin
  FCurLin := DbToLinear(FGainDb);
end;

procedure TGainNode.Process(AIn, AOut: TAudioBuffer);
var
  ch, n: Integer;
  target, glide, newLin: Double;
begin
  AOut.CopyFrom(AIn);
  n := AOut.FrameCount;
  if n <= 0 then Exit;
  target := DbToLinear(FGainDb);
  { ~15 ms glide toward the target across this block - click-free }
  glide := n / (0.015 * FSampleRate + n);
  if glide > 1.0 then glide := 1.0;
  newLin := FCurLin + (target - FCurLin) * glide;
  for ch := 0 to AOut.ChannelCount - 1 do
    BlockScaleRamp(PSingle(AOut.ChannelPtr(ch)), FCurLin, newLin, n);
  FCurLin := newLin;
end;

function TGainNode.SerializeParams: string;
begin
  Result := 'db=' + FloatId(FGainDb);
end;

procedure TGainNode.DeserializeParams(const AText: string);
begin
  FGainDb := ParamFloat(AText, 'db', 0.0);
  FCurLin := DbToLinear(FGainDb);
end;

{ ================= TPanNode ================= }

procedure TPanNode.DoConfigure;
var
  l, r: Single;
begin
  PanGains(FPos, plConstantPower, l, r);
  FCurL := l;
  FCurR := r;
end;

procedure TPanNode.Reset;
begin
  DoConfigure;
end;

procedure TPanNode.Process(AIn, AOut: TAudioBuffer);
var
  n: Integer;
  tl, tr: Single;
  glide, nl, nr: Double;
begin
  AOut.CopyFrom(AIn);
  n := AOut.FrameCount;
  if (n <= 0) or (AOut.ChannelCount < 2) then Exit;   // pan needs a stereo pair
  PanGains(FPos, plConstantPower, tl, tr);
  glide := n / (0.015 * FSampleRate + n);
  if glide > 1.0 then glide := 1.0;
  nl := FCurL + (tl - FCurL) * glide;
  nr := FCurR + (tr - FCurR) * glide;
  BlockScaleRamp(PSingle(AOut.ChannelPtr(0)), FCurL, nl, n);
  BlockScaleRamp(PSingle(AOut.ChannelPtr(1)), FCurR, nr, n);
  FCurL := nl;
  FCurR := nr;
end;

function TPanNode.SerializeParams: string;
begin
  Result := 'pos=' + FloatId(FPos);
end;

procedure TPanNode.DeserializeParams(const AText: string);
begin
  FPos := ParamFloat(AText, 'pos', 0.0);
  if FPos < -1 then FPos := -1 else if FPos > 1 then FPos := 1;
  DoConfigure;
end;

{ ================= TBiquadNode ================= }

procedure TBiquadNode.SetFilter(AKind: TBiquadKind; AFreqHz, AQ, AGainDb: Double);
begin
  FKindBq := AKind;
  FFreq := AFreqHz;
  FQ := AQ;
  FGainDb := AGainDb;
  if FConfigured then
    DoConfigure;
end;

procedure TBiquadNode.DoConfigure;
var
  ch: Integer;
begin
  if Length(FBiq) <> FChannels then
    SetLength(FBiq, FChannels);
  if FFreq <= 0 then FFreq := 1000;
  if FQ <= 0 then FQ := 0.70710678;
  for ch := 0 to FChannels - 1 do
  begin
    FBiq[ch].Init(FSampleRate);
    FBiq[ch].SetParams(FKindBq, FFreq, FQ, FGainDb);
  end;
end;

procedure TBiquadNode.Reset;
var
  ch: Integer;
begin
  for ch := 0 to High(FBiq) do
    FBiq[ch].Reset;
end;

procedure TBiquadNode.Process(AIn, AOut: TAudioBuffer);
var
  ch, n: Integer;
begin
  AOut.CopyFrom(AIn);
  n := AOut.FrameCount;
  for ch := 0 to AOut.ChannelCount - 1 do
    if ch < Length(FBiq) then
      FBiq[ch].ProcessBlock(PSingle(AOut.ChannelPtr(ch)), n);
end;

function TBiquadNode.SerializeParams: string;
begin
  Result := Format('type=%s;freq=%s;q=%s;gaindb=%s',
    [BiquadKindId(FKindBq), FloatId(FFreq), FloatId(FQ), FloatId(FGainDb)]);
end;

procedure TBiquadNode.DeserializeParams(const AText: string);
var
  k: TBiquadKind;
begin
  if not BiquadKindFromId(ParamStrDef(AText, 'type', 'lowpass'), k) then
    k := bqLowpass;
  FKindBq := k;
  FFreq := ParamFloat(AText, 'freq', 1000.0);
  FQ := ParamFloat(AText, 'q', 0.70710678);
  FGainDb := ParamFloat(AText, 'gaindb', 0.0);
  if FConfigured then DoConfigure;
end;

{ ================= TFilterChainNode ================= }

destructor TFilterChainNode.Destroy;
begin
  FreeChains;
  inherited Destroy;
end;

procedure TFilterChainNode.FreeChains;
var
  i: Integer;
begin
  for i := 0 to High(FChain) do
    FChain[i].Free;
  SetLength(FChain, 0);
end;

procedure TFilterChainNode.DoConfigure;
var
  ch: Integer;
begin
  if FPairs < 1 then FPairs := 2;
  if FPairs > 8 then FPairs := 8;
  if FFreq <= 0 then FFreq := 1000;
  if Length(FChain) <> FChannels then
  begin
    FreeChains;
    SetLength(FChain, FChannels);
    for ch := 0 to FChannels - 1 do
      FChain[ch] := TBiquadChain.Create(FSampleRate, FPairs);
  end;
  for ch := 0 to FChannels - 1 do
  begin
    FChain[ch].SetStageCount(FPairs);
    if FMode = fcHighpass then
      FChain[ch].SetButterworthHighpass(FFreq)
    else
      FChain[ch].SetButterworthLowpass(FFreq);
  end;
end;

procedure TFilterChainNode.Reset;
var
  ch: Integer;
begin
  for ch := 0 to High(FChain) do
    FChain[ch].Reset;
end;

procedure TFilterChainNode.Process(AIn, AOut: TAudioBuffer);
var
  ch, n: Integer;
begin
  AOut.CopyFrom(AIn);
  n := AOut.FrameCount;
  for ch := 0 to AOut.ChannelCount - 1 do
    if ch < Length(FChain) then
      FChain[ch].ProcessBlock(PSingle(AOut.ChannelPtr(ch)), n);
end;

function TFilterChainNode.SerializeParams: string;
var
  m: string;
begin
  if FMode = fcHighpass then m := 'hp' else m := 'lp';
  Result := Format('mode=%s;freq=%s;pairs=%d', [m, FloatId(FFreq), FPairs]);
end;

procedure TFilterChainNode.DeserializeParams(const AText: string);
begin
  if SameText(ParamStrDef(AText, 'mode', 'lp'), 'hp') then
    FMode := fcHighpass
  else
    FMode := fcLowpass;
  FFreq := ParamFloat(AText, 'freq', 1000.0);
  FPairs := ParamInt(AText, 'pairs', 2);
  if FConfigured then DoConfigure;
end;

{ ================= TDCBlockNode ================= }

procedure TDCBlockNode.DoConfigure;
var
  ch: Integer;
begin
  if FCornerHz <= 0 then FCornerHz := 20.0;
  if Length(FDC) <> FChannels then
    SetLength(FDC, FChannels);
  for ch := 0 to FChannels - 1 do
    FDC[ch].Init(FSampleRate, FCornerHz);
end;

procedure TDCBlockNode.Reset;
var
  ch: Integer;
begin
  for ch := 0 to High(FDC) do
    FDC[ch].Reset;
end;

procedure TDCBlockNode.Process(AIn, AOut: TAudioBuffer);
var
  ch, n: Integer;
begin
  AOut.CopyFrom(AIn);
  n := AOut.FrameCount;
  for ch := 0 to AOut.ChannelCount - 1 do
    if ch < Length(FDC) then
      FDC[ch].ProcessBlock(PSingle(AOut.ChannelPtr(ch)), n);
end;

function TDCBlockNode.SerializeParams: string;
begin
  Result := 'hz=' + FloatId(FCornerHz);
end;

procedure TDCBlockNode.DeserializeParams(const AText: string);
begin
  FCornerHz := ParamFloat(AText, 'hz', 20.0);
  if FConfigured then DoConfigure;
end;

{ ================= TDelayNode ================= }

procedure TDelayNode.DoConfigure;
var
  ch, want: Integer;
begin
  want := Round(DELAY_MAX_MS * 0.001 * FSampleRate) + 4;
  if (Length(FLine) <> FChannels) or (FLen <> want) then
  begin
    FLen := want;
    SetLength(FLine, FChannels);
    for ch := 0 to FChannels - 1 do
      SetLength(FLine[ch], FLen);
  end;
  if FTimeMs <= 0 then FTimeMs := 250;
  if FFeedback < 0 then FFeedback := 0 else if FFeedback > 0.95 then FFeedback := 0.95;
  if FMix < 0 then FMix := 0 else if FMix > 1 then FMix := 1;
  if FSyncBeats <= 0 then FSyncBeats := 0.5;
end;

{ Manual milliseconds by default. When FSyncBpm > 0 the repeat time is instead
  derived from project tempo + a note-division fraction (FSyncBeats, in
  quarter notes) at the moment the params are set - the audit found no
  established way for a graph node to read *live* transport tempo, so this
  recomputes ms once per DeserializeParams call rather than wiring a live BPM
  feed; a tempo change requires re-adding/re-editing the insert to pick it up. }
function TDelayNode.EffectiveTimeMs: Double;
begin
  if FSyncBpm > 0 then
    Result := (60000.0 / FSyncBpm) * FSyncBeats
  else
    Result := FTimeMs;
end;

procedure TDelayNode.Reset;
var
  ch: Integer;
begin
  for ch := 0 to High(FLine) do
    if Length(FLine[ch]) > 0 then
      FillChar(FLine[ch][0], Length(FLine[ch]) * SizeOf(Single), 0);
  FWrite := 0;
end;

procedure TDelayNode.Process(AIn, AOut: TAudioBuffer);
var
  ch, i, n, dsamp, rp, w: Integer;
  x, wet, dry, d: Double;
  src, dst: PSingle;
  line: PSingle;
  srcL, srcR, dstL, dstR, lineL, lineR: PSingle;
  xl, xr, dl, dr: Double;
begin
  n := AOut.FrameCount;
  if (FLen <= 0) or (n <= 0) then
  begin
    AOut.CopyFrom(AIn);
    Exit;
  end;
  dsamp := Round(EffectiveTimeMs * 0.001 * FSampleRate);
  if dsamp < 1 then dsamp := 1
  else if dsamp >= FLen then dsamp := FLen - 1;
  wet := FMix;
  dry := 1.0 - FMix;

  if FPingPong and (AOut.ChannelCount >= 2) and (Length(FLine) >= 2) then
  begin
    { cross-feedback stereo delay: each side's line is fed by the OTHER
      side's delayed output, so a repeat that entered on the left re-emerges
      on the right on its next bounce and vice versa }
    srcL := PSingle(AIn.ChannelPtr(0));  srcR := PSingle(AIn.ChannelPtr(1));
    dstL := PSingle(AOut.ChannelPtr(0)); dstR := PSingle(AOut.ChannelPtr(1));
    lineL := PSingle(@FLine[0][0]);      lineR := PSingle(@FLine[1][0]);
    w := FWrite;
    for i := 0 to n - 1 do
    begin
      xl := srcL[i]; xr := srcR[i];
      rp := w - dsamp;
      if rp < 0 then Inc(rp, FLen);
      dl := lineL[rp];
      dr := lineR[rp];
      lineL[w] := Single(FlushDenorm(Single(xl + dr * FFeedback)));
      lineR[w] := Single(FlushDenorm(Single(xr + dl * FFeedback)));
      dstL[i] := Single(dry * xl + wet * dl);
      dstR[i] := Single(dry * xr + wet * dr);
      Inc(w);
      if w >= FLen then w := 0;
    end;
    for ch := 2 to AOut.ChannelCount - 1 do
      BlockCopy(PSingle(AOut.ChannelPtr(ch)), PSingle(AIn.ChannelPtr(ch)), n);
    FWrite := FWrite + n;
    while FWrite >= FLen do Dec(FWrite, FLen);
    Exit;
  end;

  for ch := 0 to AOut.ChannelCount - 1 do
  begin
    if ch >= Length(FLine) then
    begin
      BlockCopy(PSingle(AOut.ChannelPtr(ch)), PSingle(AIn.ChannelPtr(ch)), n);
      Continue;
    end;
    src := PSingle(AIn.ChannelPtr(ch));
    dst := PSingle(AOut.ChannelPtr(ch));
    line := PSingle(@FLine[ch][0]);
    w := FWrite;
    for i := 0 to n - 1 do
    begin
      x := src[i];
      rp := w - dsamp;
      if rp < 0 then Inc(rp, FLen);
      d := line[rp];
      line[w] := Single(FlushDenorm(Single(x + d * FFeedback)));
      dst[i] := Single(dry * x + wet * d);
      Inc(w);
      if w >= FLen then w := 0;
    end;
  end;
  { every channel advanced the write head identically }
  FWrite := FWrite + n;
  while FWrite >= FLen do Dec(FWrite, FLen);
end;

function TDelayNode.SerializeParams: string;
begin
  Result := Format('ms=%s;fb=%s;mix=%s;pingpong=%d;syncbpm=%s;syncbeats=%s',
    [FloatId(FTimeMs), FloatId(FFeedback), FloatId(FMix), Ord(FPingPong),
     FloatId(FSyncBpm), FloatId(FSyncBeats)]);
end;

procedure TDelayNode.DeserializeParams(const AText: string);
begin
  FTimeMs := ParamFloat(AText, 'ms', 250.0);
  FFeedback := ParamFloat(AText, 'fb', 0.3);
  FMix := ParamFloat(AText, 'mix', 0.3);
  FPingPong := ParamBool(AText, 'pingpong', False);
  FSyncBpm := ParamFloat(AText, 'syncbpm', 0.0);
  FSyncBeats := ParamFloat(AText, 'syncbeats', 0.5);
  if FConfigured then DoConfigure;
end;

{ ================= TChannelMapNode ================= }

procedure TChannelMapNode.Process(AIn, AOut: TAudioBuffer);
var
  i, n: Integer;
  l, r, mid, side, wl, wr: Single;
  pl, pr, ol, or_: PSingle;
begin
  n := AOut.FrameCount;
  case FMode of
    cmSwapLR:
      begin
        AOut.CopyFrom(AIn);
        if AOut.ChannelCount >= 2 then
        begin
          Move(AIn.ChannelPtr(0)^, AOut.ChannelPtr(1)^, n * SizeOf(Single));
          Move(AIn.ChannelPtr(1)^, AOut.ChannelPtr(0)^, n * SizeOf(Single));
        end;
      end;
    cmMonoSum:
      begin
        AOut.CopyFrom(AIn);
        if AOut.ChannelCount >= 2 then
        begin
          pl := PSingle(AIn.ChannelPtr(0));
          pr := PSingle(AIn.ChannelPtr(1));
          ol := PSingle(AOut.ChannelPtr(0));
          or_ := PSingle(AOut.ChannelPtr(1));
          for i := 0 to n - 1 do
          begin
            mid := 0.5 * (pl[i] + pr[i]);
            ol[i] := mid;
            or_[i] := mid;
          end;
        end;
      end;
    cmWiden:
      begin
        AOut.CopyFrom(AIn);
        if AOut.ChannelCount >= 2 then
        begin
          pl := PSingle(AIn.ChannelPtr(0));
          pr := PSingle(AIn.ChannelPtr(1));
          ol := PSingle(AOut.ChannelPtr(0));
          or_ := PSingle(AOut.ChannelPtr(1));
          wl := 1.0; wr := Single(FWidth);
          if wr < 0 then wr := 0;
          for i := 0 to n - 1 do
          begin
            l := pl[i]; r := pr[i];
            mid := 0.5 * (l + r);
            side := 0.5 * (l - r) * wr * 2.0 * wl;
            ol[i] := mid + side;
            or_[i] := mid - side;
          end;
        end;
      end;
  else
    AOut.CopyFrom(AIn);
  end;
end;

function TChannelMapNode.SupportsChannels(ACount: Integer): Boolean;
begin
  if FMode in [cmSwapLR, cmMonoSum, cmWiden] then
    Result := ACount >= 2
  else
    Result := inherited SupportsChannels(ACount);
end;

function TChannelMapNode.SerializeParams: string;
var
  m: string;
begin
  case FMode of
    cmSwapLR:  m := 'swap';
    cmMonoSum: m := 'monosum';
    cmWiden:   m := 'widen';
  else
    m := 'passthru';
  end;
  Result := Format('mode=%s;width=%s', [m, FloatId(FWidth)]);
end;

procedure TChannelMapNode.DeserializeParams(const AText: string);
var
  m: string;
begin
  m := LowerCase(ParamStrDef(AText, 'mode', 'passthru'));
  if m = 'swap' then FMode := cmSwapLR
  else if m = 'monosum' then FMode := cmMonoSum
  else if m = 'widen' then FMode := cmWiden
  else FMode := cmPassthru;
  FWidth := ParamFloat(AText, 'width', 1.0);
end;

{ ================= TMeterNode ================= }

destructor TMeterNode.Destroy;
begin
  FLoud.Free;
  inherited Destroy;
end;

procedure TMeterNode.DoConfigure;
begin
  FPeak.Init(FSampleRate, 20.0, 1500.0, 10.0);
  FRms.Init(FSampleRate, 300.0);
  FTruePeak.Init(FSampleRate, 4, 24);
  FreeAndNil(FLoud);
  { always a stereo K-weighting chain; a mono tap feeds the same sample to
    both sides, which is the BS.1770 mono convention. }
  FLoud := TLoudnessMeter.Create(FSampleRate, 2);
end;

procedure TMeterNode.Reset;
begin
  FPeak.Reset;
  FRms.Reset;
  FTruePeak.Reset;
  if FLoud <> nil then FLoud.Reset;
  FPeakDb := METER_MIN_DB;
  FRmsDb := METER_MIN_DB;
  FTruePeakDb := METER_MIN_DB;
  FMomentaryLufs := -70.0;
  FIntegratedLufs := -70.0;
end;

procedure TMeterNode.Process(AIn, AOut: TAudioBuffer);
var
  i, n, lc: Integer;
  p0: PSingle;
  fr: array[0..1] of Single;
begin
  AOut.CopyFrom(AIn);
  n := AOut.FrameCount;
  if n <= 0 then Exit;

  p0 := PSingle(AOut.ChannelPtr(0));
  FPeak.PushBlock(p0, n);
  FRms.PushBlock(p0, n);
  FTruePeak.PushBlock(p0, n);

  lc := AOut.ChannelCount;
  if FLoud <> nil then
  begin
    if lc >= 2 then
    begin
      for i := 0 to n - 1 do
      begin
        fr[0] := AOut.ChannelPtr(0)[i];
        fr[1] := AOut.ChannelPtr(1)[i];
        FLoud.PushFrame(fr);
      end;
    end
    else
    begin
      for i := 0 to n - 1 do
      begin
        fr[0] := p0[i];
        fr[1] := p0[i];
        FLoud.PushFrame(fr);
      end;
    end;
  end;

  FPeakDb := FPeak.ValueDb;
  FRmsDb := FRms.ValueDb;
  FTruePeakDb := FTruePeak.ValueDb;
  if FLoud <> nil then
  begin
    FMomentaryLufs := FLoud.Momentary;
    FIntegratedLufs := FLoud.Integrated;
  end;
end;

{ ================= TScopeNode ================= }

destructor TScopeNode.Destroy;
begin
  FSpectrum.Free;
  FGonio.Free;
  FScope.Free;
  inherited Destroy;
end;

procedure TScopeNode.DoConfigure;
var
  ch: Integer;
begin
  if FSpectrum = nil then FSpectrum := TSpectrumAnalyzer.Create;
  FSpectrum.Configure(FSampleRate, 2048);
  if FGonio = nil then FGonio := TGoniometer.Create;
  FGonio.Configure(FSampleRate, 2048);
  if FScope = nil then FScope := TOscilloscopeCapture.Create;
  FScope.Configure(FSampleRate, 2048);
  FScope.SetTriggerMode(True);
  if Length(FMonoScratch) <> FMaxFrames then SetLength(FMonoScratch, FMaxFrames);
  SetLength(FBallistics, FChannels);
  for ch := 0 to FChannels - 1 do
    FBallistics[ch].Configure(FSampleRate, FPreset);
end;

procedure TScopeNode.Reset;
var
  ch: Integer;
begin
  if FSpectrum <> nil then FSpectrum.Reset;
  if FGonio <> nil then FGonio.Reset;
  if FScope <> nil then FScope.Reset;
  for ch := 0 to High(FBallistics) do
    FBallistics[ch].Reset;
end;

procedure TScopeNode.Process(AIn, AOut: TAudioBuffer);
var
  i, n, lc, ch: Integer;
  p0, p1: PSingle;
begin
  AOut.CopyFrom(AIn);
  n := AOut.FrameCount;
  if n <= 0 then Exit;

  lc := AOut.ChannelCount;
  p0 := PSingle(AOut.ChannelPtr(0));
  p1 := p0;

  if lc >= 2 then
  begin
    p1 := PSingle(AOut.ChannelPtr(1));
    FGonio.PushBlock(p0, p1, n);
  end
  else
    FGonio.PushBlock(p0, p0, n);

  { spectrum / scope run on a mono sum of whatever channels are present,
    left untouched in the output - this node is a unity-pass analysis tap }
  if Length(FMonoScratch) < n then SetLength(FMonoScratch, n);
  if lc >= 2 then
    for i := 0 to n - 1 do
      FMonoScratch[i] := 0.5 * (p0[i] + p1[i])
  else
    for i := 0 to n - 1 do
      FMonoScratch[i] := p0[i];
  FSpectrum.PushBlock(@FMonoScratch[0], n);
  FScope.PushBlock(@FMonoScratch[0], n);

  for ch := 0 to lc - 1 do
    if ch <= High(FBallistics) then
      FBallistics[ch].PushBlock(PSingle(AOut.ChannelPtr(ch)), n);
end;

function TScopeNode.SerializeParams: string;
begin
  Result := 'preset=' + MeterBallisticsId(FPreset);
end;

procedure TScopeNode.DeserializeParams(const AText: string);
var
  p: TMeterBallistics;
  ch: Integer;
begin
  if MeterBallisticsFromId(ParamStrDef(AText, 'preset', 'peak'), p) then
    FPreset := p
  else
    FPreset := mbDigitalPeak;
  if FConfigured then
    for ch := 0 to High(FBallistics) do
      FBallistics[ch].Configure(FSampleRate, FPreset);
end;

procedure TScopeNode.GetSpectrumDb(var ADb: array of Double);
begin
  if FSpectrum <> nil then FSpectrum.GetSpectrumDb(ADb);
end;

procedure TScopeNode.GetSpectrumPeakDb(var ADb: array of Double);
begin
  if FSpectrum <> nil then FSpectrum.GetPeakDb(ADb);
end;

function TScopeNode.SpectrumBins: Integer;
begin
  if FSpectrum <> nil then Result := FSpectrum.SpectrumBins else Result := 0;
end;

procedure TScopeNode.GetOscilloscopeSnapshot(var ABuf: array of Single; out ACount: Integer);
begin
  ACount := 0;
  if FScope <> nil then ACount := FScope.GetSnapshot(ABuf);
end;

function TScopeNode.Correlation: Double;
begin
  if FGonio <> nil then Result := FGonio.Correlation else Result := 0;
end;

function TScopeNode.WidthEstimate: Double;
begin
  if FGonio <> nil then Result := FGonio.WidthEstimate else Result := 0;
end;

function TScopeNode.BallisticReadingDb(AChannel: Integer): Double;
begin
  if (AChannel >= 0) and (AChannel <= High(FBallistics)) then
    Result := FBallistics[AChannel].ReadingDb
  else
    Result := METER_MIN_DB;
end;

function TScopeNode.BallisticReadingScale01(AChannel: Integer): Double;
begin
  if (AChannel >= 0) and (AChannel <= High(FBallistics)) then
    Result := FBallistics[AChannel].ReadingScale01
  else
    Result := 0;
end;

{ ================= TEffectNodeBase ================= }

procedure TEffectNodeBase.GatherPtrs(AIn, AOut: TAudioBuffer; out ANC: Integer);
var
  ch: Integer;
begin
  ANC := AOut.ChannelCount;
  if AIn.ChannelCount < ANC then ANC := AIn.ChannelCount;
  { SetLength is a no-op once the channel geometry has settled (it never
    changes at run time), so the RT path allocates nothing. }
  if Length(FInPtrs) <> ANC then SetLength(FInPtrs, ANC);
  if Length(FOutPtrs) <> ANC then SetLength(FOutPtrs, ANC);
  for ch := 0 to ANC - 1 do
  begin
    FInPtrs[ch] := PSingle(AIn.ChannelPtr(ch));
    FOutPtrs[ch] := PSingle(AOut.ChannelPtr(ch));
  end;
end;

{ ================= TCompressorNode ================= }

destructor TCompressorNode.Destroy;
begin
  FProc.Free;
  inherited Destroy;
end;

procedure TCompressorNode.DoConfigure;
begin
  if FProc = nil then FProc := TDynamicsProcessor.Create;
  if FThresh = 0 then FThresh := -18.0;
  if FRatio = 0 then FRatio := 3.0;
  if FAttack = 0 then FAttack := 10.0;
  if FRelease = 0 then FRelease := 120.0;
  if FHold = 0 then FHold := 20.0;
  if FRange = 0 then FRange := -60.0;
  if FScFreq = 0 then FScFreq := 6000.0;
  FProc.Configure(FSampleRate, FChannels);
  FProc.SetParams(FMode, FThresh, FRatio, FKnee, FAttack, FRelease, FMakeup);
  FProc.SetGateParams(FHold, FRange);
  FProc.SetDeEsserFreq(FScFreq);
  SetLength(FScPtrs, FChannels);
end;

procedure TCompressorNode.Reset;
begin
  if FProc <> nil then FProc.Reset;
end;

procedure TCompressorNode.SetSidechain(ABuffer: TAudioBuffer);
begin
  FSc := ABuffer;
end;

procedure TCompressorNode.Process(AIn, AOut: TAudioBuffer);
var
  nc, ch, n, scn: Integer;
  empty: array of PSingle;
begin
  n := AOut.FrameCount;
  GatherPtrs(AIn, AOut, nc);
  if (nc = 0) or (n = 0) then Exit;
  if (FSc <> nil) and (FSc.FrameCount >= n) and (FSc.ChannelCount >= 1) then
  begin
    scn := FSc.ChannelCount;
    if Length(FScPtrs) < scn then SetLength(FScPtrs, scn);
    for ch := 0 to scn - 1 do
      FScPtrs[ch] := PSingle(FSc.ChannelPtr(ch));
    FProc.ProcessBlock(FInPtrs, FOutPtrs, n,
      FScPtrs);
  end
  else
  begin
    SetLength(empty, 0);
    FProc.ProcessBlock(FInPtrs, FOutPtrs, n, empty);
  end;
end;

function TCompressorNode.GainReductionDb: Double;
begin
  if FProc <> nil then Result := FProc.CurrentGainReductionDb else Result := 0;
end;

function TCompressorNode.SerializeParams: string;
begin
  Result := Format('type=%s;thresh=%s;ratio=%s;knee=%s;attack=%s;release=%s;makeup=%s;hold=%s;range=%s;scfreq=%s',
    [DynamicsModeId(FMode), FloatId(FThresh), FloatId(FRatio), FloatId(FKnee),
     FloatId(FAttack), FloatId(FRelease), FloatId(FMakeup), FloatId(FHold),
     FloatId(FRange), FloatId(FScFreq)]);
end;

procedure TCompressorNode.DeserializeParams(const AText: string);
var
  m: TDynamicsMode;
begin
  if not DynamicsModeFromId(ParamStrDef(AText, 'type', 'compressor'), m) then
    m := dynCompressor;
  FMode := m;
  FThresh := ParamFloat(AText, 'thresh', -18.0);
  FRatio := ParamFloat(AText, 'ratio', 3.0);
  FKnee := ParamFloat(AText, 'knee', 6.0);
  FAttack := ParamFloat(AText, 'attack', 10.0);
  FRelease := ParamFloat(AText, 'release', 120.0);
  FMakeup := ParamFloat(AText, 'makeup', 0.0);
  FHold := ParamFloat(AText, 'hold', 20.0);
  FRange := ParamFloat(AText, 'range', -60.0);
  FScFreq := ParamFloat(AText, 'scfreq', 6000.0);
  if FConfigured then DoConfigure;
end;

{ ================= TModulationNode ================= }

destructor TModulationNode.Destroy;
begin
  FProc.Free;
  inherited Destroy;
end;

procedure TModulationNode.DoConfigure;
begin
  if FProc = nil then FProc := TModulationProcessor.Create;
  if FRate = 0 then FRate := 0.5;
  if FStages = 0 then FStages := 4;
  FProc.Configure(FSampleRate, FChannels);
  FProc.SetParams(FEffect, FRate, FDepth, FMix, FFeedback, FStages, FStereo);
end;

procedure TModulationNode.Reset;
begin
  if FProc <> nil then FProc.Reset;
end;

procedure TModulationNode.Process(AIn, AOut: TAudioBuffer);
var
  nc, n: Integer;
begin
  n := AOut.FrameCount;
  GatherPtrs(AIn, AOut, nc);
  if (nc = 0) or (n = 0) then Exit;
  FProc.ProcessBlock(FInPtrs, FOutPtrs, n);
end;

function TModulationNode.SerializeParams: string;
begin
  Result := Format('type=%s;rate=%s;depth=%s;mix=%s;fb=%s;stages=%d;stereo=%s',
    [ModEffectId(FEffect), FloatId(FRate), FloatId(FDepth), FloatId(FMix),
     FloatId(FFeedback), FStages, FloatId(FStereo)]);
end;

procedure TModulationNode.DeserializeParams(const AText: string);
var
  e: TModEffect;
begin
  if not ModEffectFromId(ParamStrDef(AText, 'type', 'chorus'), e) then
    e := modChorus;
  FEffect := e;
  FRate := ParamFloat(AText, 'rate', 0.5);
  FDepth := ParamFloat(AText, 'depth', 0.6);
  FMix := ParamFloat(AText, 'mix', 0.5);
  FFeedback := ParamFloat(AText, 'fb', 0.0);
  FStages := ParamInt(AText, 'stages', 4);
  FStereo := ParamFloat(AText, 'stereo', 90.0);
  if FConfigured then DoConfigure;
end;

{ ================= TDistortionNode ================= }

destructor TDistortionNode.Destroy;
begin
  FProc.Free;
  inherited Destroy;
end;

procedure TDistortionNode.DoConfigure;
begin
  if FProc = nil then FProc := TDistortionProcessor.Create;
  if FDrive = 0 then FDrive := 2.0;
  if FMix = 0 then FMix := 1.0;
  if FBits = 0 then FBits := 8.0;
  if FDown = 0 then FDown := 1;
  if FOs = 0 then FOs := 2;
  FProc.Configure(FSampleRate, FChannels);
  FProc.SetParams(FMode, FDrive, FTrimDb, FMix, FBits, FDown, FOs);
end;

procedure TDistortionNode.Reset;
begin
  if FProc <> nil then FProc.Reset;
end;

procedure TDistortionNode.Process(AIn, AOut: TAudioBuffer);
var
  nc, n: Integer;
begin
  n := AOut.FrameCount;
  GatherPtrs(AIn, AOut, nc);
  if (nc = 0) or (n = 0) then Exit;
  FProc.ProcessBlock(FInPtrs, FOutPtrs, n);
end;

function TDistortionNode.SerializeParams: string;
begin
  Result := Format('type=%s;drive=%s;trim=%s;mix=%s;bits=%s;down=%d;os=%d',
    [DistModeId(FMode), FloatId(FDrive), FloatId(FTrimDb), FloatId(FMix),
     FloatId(FBits), FDown, FOs]);
end;

procedure TDistortionNode.DeserializeParams(const AText: string);
var
  m: TDistMode;
begin
  if not DistModeFromId(ParamStrDef(AText, 'type', 'saturation'), m) then
    m := distSaturation;
  FMode := m;
  FDrive := ParamFloat(AText, 'drive', 2.0);
  FTrimDb := ParamFloat(AText, 'trim', 0.0);
  FMix := ParamFloat(AText, 'mix', 1.0);
  FBits := ParamFloat(AText, 'bits', 8.0);
  FDown := ParamInt(AText, 'down', 1);
  FOs := ParamInt(AText, 'os', 2);
  if FConfigured then DoConfigure;
end;

{ ================= TReverbNode ================= }

destructor TReverbNode.Destroy;
begin
  FProc.Free;
  inherited Destroy;
end;

procedure TReverbNode.DoConfigure;
begin
  if FProc = nil then FProc := TAlgoReverb.Create;
  if FSize = 0 then FSize := 0.7;
  if FDamp = 0 then FDamp := 0.4;
  if FWidth = 0 then FWidth := 1.0;
  if FMix = 0 then FMix := 0.3;
  if FPreDelay = 0 then FPreDelay := 15.0;
  if FEarly = 0 then FEarly := 0.5;
  if FTail = 0 then FTail := 0.9;
  FProc.Configure(FSampleRate);
  FProc.SetParams(FSize, FDamp, FWidth, FMix, FPreDelay, FEarly, FTail);
end;

procedure TReverbNode.Reset;
begin
  if FProc <> nil then FProc.Reset;
end;

procedure TReverbNode.Process(AIn, AOut: TAudioBuffer);
var
  nc, n: Integer;
begin
  n := AOut.FrameCount;
  GatherPtrs(AIn, AOut, nc);
  if (nc = 0) or (n = 0) then Exit;
  FProc.ProcessBlock(FInPtrs, FOutPtrs, n);
end;

function TReverbNode.SerializeParams: string;
begin
  Result := Format('size=%s;damp=%s;width=%s;mix=%s;predelay=%s;early=%s;tail=%s',
    [FloatId(FSize), FloatId(FDamp), FloatId(FWidth), FloatId(FMix),
     FloatId(FPreDelay), FloatId(FEarly), FloatId(FTail)]);
end;

procedure TReverbNode.DeserializeParams(const AText: string);
begin
  FSize := ParamFloat(AText, 'size', 0.7);
  FDamp := ParamFloat(AText, 'damp', 0.4);
  FWidth := ParamFloat(AText, 'width', 1.0);
  FMix := ParamFloat(AText, 'mix', 0.3);
  FPreDelay := ParamFloat(AText, 'predelay', 15.0);
  FEarly := ParamFloat(AText, 'early', 0.5);
  FTail := ParamFloat(AText, 'tail', 0.9);
  if FConfigured then DoConfigure;
end;

{ ================= TGraphicEQNode ================= }

destructor TGraphicEQNode.Destroy;
begin
  FProc.Free;
  inherited Destroy;
end;

procedure TGraphicEQNode.DoConfigure;
var
  i: Integer;
begin
  if FProc = nil then FProc := TGraphicEQ.Create;
  if FBands < 1 then FBands := 10;
  FProc.SetBandCount(FBands);
  FProc.Configure(FSampleRate, FChannels);
  for i := 0 to High(FGains) do
    FProc.SetBandGain(i, FGains[i]);
end;

procedure TGraphicEQNode.Reset;
begin
  if FProc <> nil then FProc.Reset;
end;

procedure TGraphicEQNode.Process(AIn, AOut: TAudioBuffer);
var
  nc, n: Integer;
begin
  n := AOut.FrameCount;
  GatherPtrs(AIn, AOut, nc);
  if (nc = 0) or (n = 0) then Exit;
  FProc.ProcessBlock(FInPtrs, FOutPtrs, n);
end;

function TGraphicEQNode.SerializeParams: string;
var
  i: Integer;
  g: string;
begin
  g := '';
  for i := 0 to FBands - 1 do
  begin
    if g <> '' then g := g + ',';
    if i < Length(FGains) then g := g + FloatId(FGains[i]) else g := g + '0';
  end;
  Result := Format('bands=%d;gains=%s', [FBands, g]);
end;

procedure TGraphicEQNode.DeserializeParams(const AText: string);
var
  parts: TArray<string>;
  i: Integer;
  v: Double;
begin
  FBands := ParamInt(AText, 'bands', 10);
  if FBands < 1 then FBands := 1 else if FBands > GEQ_MAX_BANDS then FBands := GEQ_MAX_BANDS;
  SetLength(FGains, FBands);
  for i := 0 to FBands - 1 do FGains[i] := 0;
  parts := ParamStrDef(AText, 'gains', '').Split([',']);
  for i := 0 to High(parts) do
  begin
    if i >= FBands then Break;
    if TryStrToFloat(Trim(parts[i]), v, TFormatSettings.Invariant) then
      FGains[i] := v;
  end;
  if FConfigured then DoConfigure;
end;

procedure TGraphicEQNode.ApplyGainsLive(const AText: string);
var
  parts: TArray<string>;
  i: Integer;
  v: Double;
begin
  if FProc = nil then Exit;
  parts := ParamStrDef(AText, 'gains', '').Split([',']);
  for i := 0 to High(FGains) do
  begin
    v := 0;
    if i <= High(parts) then
      if not TryStrToFloat(Trim(parts[i]), v, TFormatSettings.Invariant) then v := 0;
    FGains[i] := v;
    FProc.SetBandGain(i, v);
  end;
end;

{ ================= TMultibandCompNode ================= }

destructor TMultibandCompNode.Destroy;
begin
  FProc.Free;
  inherited Destroy;
end;

procedure TMultibandCompNode.DoConfigure;
var
  b: Integer;
begin
  if FProc = nil then FProc := TMultibandCompressor.Create;
  if FLowMidHz = 0 then FLowMidHz := 200.0;
  if FMidHighHz = 0 then FMidHighHz := 2000.0;
  for b := 0 to 2 do
  begin
    if FRatio[b] = 0 then FRatio[b] := 3.0;
    if FKnee[b] = 0 then FKnee[b] := 6.0;
    if FAttack[b] = 0 then FAttack[b] := 10.0;
    if FRelease[b] = 0 then FRelease[b] := 120.0;
    if FThresh[b] = 0 then FThresh[b] := -18.0;
  end;
  FProc.Configure(FSampleRate, FChannels);
  FProc.SetCrossovers(FLowMidHz, FMidHighHz);
  for b := 0 to 2 do
    FProc.SetBandParams(b, FThresh[b], FRatio[b], FKnee[b], FAttack[b], FRelease[b], FMakeup[b]);
end;

procedure TMultibandCompNode.Reset;
begin
  if FProc <> nil then FProc.Reset;
end;

procedure TMultibandCompNode.Process(AIn, AOut: TAudioBuffer);
var
  nc, n: Integer;
begin
  n := AOut.FrameCount;
  GatherPtrs(AIn, AOut, nc);
  if (nc = 0) or (n = 0) then Exit;
  FProc.ProcessBlock(FInPtrs, FOutPtrs, n);
end;

function TMultibandCompNode.BandGainReductionDb(ABand: Integer): Double;
begin
  if FProc <> nil then Result := FProc.BandGainReductionDb(ABand) else Result := 0;
end;

function TMultibandCompNode.SerializeParams: string;
begin
  Result := Format(
    'lowmid=%s;midhigh=%s;' +
    'b0thresh=%s;b0ratio=%s;b0knee=%s;b0attack=%s;b0release=%s;b0makeup=%s;' +
    'b1thresh=%s;b1ratio=%s;b1knee=%s;b1attack=%s;b1release=%s;b1makeup=%s;' +
    'b2thresh=%s;b2ratio=%s;b2knee=%s;b2attack=%s;b2release=%s;b2makeup=%s',
    [FloatId(FLowMidHz), FloatId(FMidHighHz),
     FloatId(FThresh[0]), FloatId(FRatio[0]), FloatId(FKnee[0]), FloatId(FAttack[0]), FloatId(FRelease[0]), FloatId(FMakeup[0]),
     FloatId(FThresh[1]), FloatId(FRatio[1]), FloatId(FKnee[1]), FloatId(FAttack[1]), FloatId(FRelease[1]), FloatId(FMakeup[1]),
     FloatId(FThresh[2]), FloatId(FRatio[2]), FloatId(FKnee[2]), FloatId(FAttack[2]), FloatId(FRelease[2]), FloatId(FMakeup[2])]);
end;

procedure TMultibandCompNode.DeserializeParams(const AText: string);
const
  PFX: array[0..2] of string = ('b0', 'b1', 'b2');
var
  b: Integer;
begin
  FLowMidHz := ParamFloat(AText, 'lowmid', 200.0);
  FMidHighHz := ParamFloat(AText, 'midhigh', 2000.0);
  for b := 0 to 2 do
  begin
    FThresh[b] := ParamFloat(AText, PFX[b] + 'thresh', -18.0);
    FRatio[b] := ParamFloat(AText, PFX[b] + 'ratio', 3.0);
    FKnee[b] := ParamFloat(AText, PFX[b] + 'knee', 6.0);
    FAttack[b] := ParamFloat(AText, PFX[b] + 'attack', 10.0);
    FRelease[b] := ParamFloat(AText, PFX[b] + 'release', 120.0);
    FMakeup[b] := ParamFloat(AText, PFX[b] + 'makeup', 0.0);
  end;
  if FConfigured then DoConfigure;
end;

{ ================= TMasteringNode ================= }

destructor TMasteringNode.Destroy;
begin
  FProc.Free;
  inherited Destroy;
end;

procedure TMasteringNode.DoConfigure;
begin
  if FProc = nil then FProc := TMasteringChain.Create;
  if FCeilingDb = 0 then FCeilingDb := -1.0;
  if FTargetLufs = 0 then FTargetLufs := -14.0;
  if FWidth = 0 then FWidth := 1.0;
  FProc.Configure(FSampleRate);
  FProc.SetCeilingDb(FCeilingDb);
  FProc.SetTargetLufs(FTargetLufs);
  FProc.SetWidthAmount(FWidth);
end;

procedure TMasteringNode.Reset;
begin
  if FProc <> nil then FProc.Reset;
end;

procedure TMasteringNode.Process(AIn, AOut: TAudioBuffer);
var
  nc, n: Integer;
begin
  n := AOut.FrameCount;
  GatherPtrs(AIn, AOut, nc);
  if (nc < 2) or (n = 0) then
  begin
    AOut.CopyFrom(AIn);
    Exit;
  end;
  FProc.ProcessBlock(FInPtrs, FOutPtrs, n);
end;

function TMasteringNode.CurrentTruePeakDb: Double;
begin
  if FProc <> nil then Result := FProc.CurrentTruePeakDb else Result := 0;
end;

function TMasteringNode.CurrentIntegratedLufs: Double;
begin
  if FProc <> nil then Result := FProc.CurrentIntegratedLufs else Result := 0;
end;

function TMasteringNode.SerializeParams: string;
begin
  Result := Format('ceiling=%s;target=%s;width=%s',
    [FloatId(FCeilingDb), FloatId(FTargetLufs), FloatId(FWidth)]);
end;

procedure TMasteringNode.DeserializeParams(const AText: string);
begin
  FCeilingDb := ParamFloat(AText, 'ceiling', -1.0);
  FTargetLufs := ParamFloat(AText, 'target', -14.0);
  FWidth := ParamFloat(AText, 'width', 1.0);
  if FConfigured then DoConfigure;
end;

{ ================= TParametricEQNode ================= }

destructor TParametricEQNode.Destroy;
begin
  FProc.Free;
  inherited Destroy;
end;

procedure TParametricEQNode.DoConfigure;
var
  i: Integer;
const
  DefaultFreqs: array[0..PEQ_BAND_COUNT - 1] of Double = (80, 250, 1000, 3000, 6000, 12000);
begin
  if FProc = nil then FProc := TParametricEQ.Create;
  for i := 0 to PEQ_BAND_COUNT - 1 do
    if FBandFreq[i] = 0 then
    begin
      FBandFreq[i] := DefaultFreqs[i];
      FBandQ[i] := 0.7071;
      if i = 0 then FBandType[i] := peqLowShelf
      else if i = PEQ_BAND_COUNT - 1 then FBandType[i] := peqHighShelf
      else FBandType[i] := peqPeaking;
    end;
  FProc.Configure(FSampleRate, FChannels);
  for i := 0 to PEQ_BAND_COUNT - 1 do
    FProc.SetBand(i, FBandType[i], FBandFreq[i], FBandGain[i], FBandQ[i]);
end;

procedure TParametricEQNode.Reset;
begin
  if FProc <> nil then FProc.Reset;
end;

procedure TParametricEQNode.Process(AIn, AOut: TAudioBuffer);
var
  nc, n: Integer;
begin
  n := AOut.FrameCount;
  GatherPtrs(AIn, AOut, nc);
  if (nc = 0) or (n = 0) then Exit;
  FProc.ProcessBlock(FInPtrs, FOutPtrs, n);
end;

function TParametricEQNode.SerializeParams: string;
var
  i: Integer;
  s: string;
begin
  s := '';
  for i := 0 to PEQ_BAND_COUNT - 1 do
    s := s + Format('b%dtype=%s;b%dfreq=%s;b%dgain=%s;b%dq=%s;',
      [i, PEQBandTypeId(FBandType[i]), i, FloatId(FBandFreq[i]),
       i, FloatId(FBandGain[i]), i, FloatId(FBandQ[i])]);
  Result := s;
end;

procedure TParametricEQNode.DeserializeParams(const AText: string);
var
  i: Integer;
  t: TPEQBandType;
const
  DefaultFreqs: array[0..PEQ_BAND_COUNT - 1] of Double = (80, 250, 1000, 3000, 6000, 12000);
begin
  for i := 0 to PEQ_BAND_COUNT - 1 do
  begin
    if not PEQBandTypeFromId(ParamStrDef(AText, Format('b%dtype', [i]), ''), t) then
    begin
      if i = 0 then t := peqLowShelf
      else if i = PEQ_BAND_COUNT - 1 then t := peqHighShelf
      else t := peqPeaking;
    end;
    FBandType[i] := t;
    FBandFreq[i] := ParamFloat(AText, Format('b%dfreq', [i]), DefaultFreqs[i]);
    FBandGain[i] := ParamFloat(AText, Format('b%dgain', [i]), 0.0);
    FBandQ[i] := ParamFloat(AText, Format('b%dq', [i]), 0.7071);
  end;
  if FConfigured then DoConfigure;
end;

{ ================= TStereoWidthNode ================= }

destructor TStereoWidthNode.Destroy;
begin
  FProc.Free;
  inherited Destroy;
end;

procedure TStereoWidthNode.DoConfigure;
begin
  if FProc = nil then FProc := TStereoWidthProcessor.Create;
  if FWidth = 0 then FWidth := 1.0;
  FProc.Configure(FSampleRate, FChannels);
  FProc.SetParams(FWidth);
end;

procedure TStereoWidthNode.Reset;
begin
  if FProc <> nil then FProc.Reset;
end;

procedure TStereoWidthNode.Process(AIn, AOut: TAudioBuffer);
var
  nc, n: Integer;
begin
  n := AOut.FrameCount;
  GatherPtrs(AIn, AOut, nc);
  if (nc = 0) or (n = 0) then Exit;
  FProc.ProcessBlock(FInPtrs, FOutPtrs, n);
end;

function TStereoWidthNode.SerializeParams: string;
begin
  Result := 'width=' + FloatId(FWidth);
end;

procedure TStereoWidthNode.DeserializeParams(const AText: string);
begin
  FWidth := ParamFloat(AText, 'width', 1.0);
  if FConfigured then DoConfigure;
end;

{ ================= TTransientShaperNode ================= }

destructor TTransientShaperNode.Destroy;
begin
  FProc.Free;
  inherited Destroy;
end;

procedure TTransientShaperNode.DoConfigure;
begin
  if FProc = nil then FProc := TTransientShaper.Create;
  FProc.Configure(FSampleRate, FChannels);
  FProc.SetParams(FAttackDb, FSustainDb);
end;

procedure TTransientShaperNode.Reset;
begin
  if FProc <> nil then FProc.Reset;
end;

procedure TTransientShaperNode.Process(AIn, AOut: TAudioBuffer);
var
  nc, n: Integer;
begin
  n := AOut.FrameCount;
  GatherPtrs(AIn, AOut, nc);
  if (nc = 0) or (n = 0) then Exit;
  FProc.ProcessBlock(FInPtrs, FOutPtrs, n);
end;

function TTransientShaperNode.SerializeParams: string;
begin
  Result := Format('attack=%s;sustain=%s', [FloatId(FAttackDb), FloatId(FSustainDb)]);
end;

procedure TTransientShaperNode.DeserializeParams(const AText: string);
begin
  FAttackDb := ParamFloat(AText, 'attack', 6.0);
  FSustainDb := ParamFloat(AText, 'sustain', 0.0);
  if FConfigured then DoConfigure;
end;

{ ================= TExciterNode ================= }

destructor TExciterNode.Destroy;
begin
  FProc.Free;
  inherited Destroy;
end;

procedure TExciterNode.DoConfigure;
begin
  if FProc = nil then FProc := TExciter.Create;
  if FFreqHz = 0 then FFreqHz := 3000.0;
  if FDrive = 0 then FDrive := 4.0;
  if FMix = 0 then FMix := 0.25;
  if FOs = 0 then FOs := 2;
  FProc.Configure(FSampleRate, FChannels);
  FProc.SetParams(FFreqHz, FDrive, FMix, FOs);
end;

procedure TExciterNode.Reset;
begin
  if FProc <> nil then FProc.Reset;
end;

procedure TExciterNode.Process(AIn, AOut: TAudioBuffer);
var
  nc, n: Integer;
begin
  n := AOut.FrameCount;
  GatherPtrs(AIn, AOut, nc);
  if (nc = 0) or (n = 0) then Exit;
  FProc.ProcessBlock(FInPtrs, FOutPtrs, n);
end;

function TExciterNode.SerializeParams: string;
begin
  Result := Format('freq=%s;drive=%s;mix=%s;os=%d', [FloatId(FFreqHz), FloatId(FDrive), FloatId(FMix), FOs]);
end;

procedure TExciterNode.DeserializeParams(const AText: string);
begin
  FFreqHz := ParamFloat(AText, 'freq', 3000.0);
  FDrive := ParamFloat(AText, 'drive', 4.0);
  FMix := ParamFloat(AText, 'mix', 0.25);
  FOs := ParamInt(AText, 'os', 2);
  if FConfigured then DoConfigure;
end;

{ ================= TLookaheadLimiterNode ================= }

destructor TLookaheadLimiterNode.Destroy;
begin
  FProc.Free;
  inherited Destroy;
end;

procedure TLookaheadLimiterNode.DoConfigure;
begin
  if FProc = nil then FProc := TLookaheadLimiter.Create;
  if FCeilingDb = 0 then FCeilingDb := -0.3;
  if FReleaseMs = 0 then FReleaseMs := 100.0;
  if FLookaheadMs = 0 then FLookaheadMs := 5.0;
  FProc.Configure(FSampleRate, FChannels);
  FProc.SetParams(FCeilingDb, FReleaseMs, FLookaheadMs);
end;

procedure TLookaheadLimiterNode.Reset;
begin
  if FProc <> nil then FProc.Reset;
end;

procedure TLookaheadLimiterNode.Process(AIn, AOut: TAudioBuffer);
var
  nc, n: Integer;
begin
  n := AOut.FrameCount;
  GatherPtrs(AIn, AOut, nc);
  if (nc = 0) or (n = 0) then Exit;
  FProc.ProcessBlock(FInPtrs, FOutPtrs, n);
end;

function TLookaheadLimiterNode.GainReductionDb: Double;
begin
  if FProc <> nil then Result := FProc.CurrentGainReductionDb else Result := 0;
end;

function TLookaheadLimiterNode.SerializeParams: string;
begin
  Result := Format('ceiling=%s;release=%s;lookahead=%s',
    [FloatId(FCeilingDb), FloatId(FReleaseMs), FloatId(FLookaheadMs)]);
end;

procedure TLookaheadLimiterNode.DeserializeParams(const AText: string);
begin
  FCeilingDb := ParamFloat(AText, 'ceiling', -0.3);
  FReleaseMs := ParamFloat(AText, 'release', 100.0);
  FLookaheadMs := ParamFloat(AText, 'lookahead', 5.0);
  if FConfigured then DoConfigure;
end;

{ ================= TPitchShiftNode ================= }

const
  PS_CHUNK = 4096;
  PS_HOP = PS_CHUNK div 2;
  PS_RING_LEN = PS_CHUNK * 4;

destructor TPitchShiftNode.Destroy;
begin
  FShifter.Free;
  inherited Destroy;
end;

procedure TPitchShiftNode.DoConfigure;
begin
  if FShifter = nil then FShifter := TPitchShifter.Create;
  EnsureAlloc;
  Reset;
end;

procedure TPitchShiftNode.EnsureAlloc;
var
  ch, i: Integer;
begin
  if Length(FWindow) <> PS_CHUNK then
  begin
    SetLength(FWindow, PS_CHUNK);
    for i := 0 to PS_CHUNK - 1 do
      FWindow[i] := Single(0.5 - 0.5 * FastCos(DSP_TWO_PI * i / PS_CHUNK));
  end;
  if Length(FInWin) <> FChannels then
  begin
    SetLength(FInWin, FChannels);
    SetLength(FOlaBuf, FChannels);
    SetLength(FRing, FChannels);
    SetLength(FInFill, FChannels);
    SetLength(FRingRead, FChannels);
    SetLength(FRingWrite, FChannels);
    SetLength(FRingCount, FChannels);
    FRingLen := PS_RING_LEN;
    for ch := 0 to FChannels - 1 do
    begin
      SetLength(FInWin[ch], PS_CHUNK);
      SetLength(FOlaBuf[ch], PS_CHUNK);
      SetLength(FRing[ch], FRingLen);
    end;
  end;
end;

procedure TPitchShiftNode.RunHop(AChannel: Integer);
var
  shifted: TArray<Single>;
  i, wp: Integer;
  ola: PSingle;
begin
  FShifter.Process(FInWin[AChannel], FSemitones, FSampleRate, shifted);
  if Length(shifted) < PS_CHUNK then SetLength(shifted, PS_CHUNK);

  ola := @FOlaBuf[AChannel][0];
  for i := 0 to PS_CHUNK - 1 do
    ola[i] := ola[i] + shifted[i] * FWindow[i];

  { emit the front PS_HOP samples of the OLA accumulator into the output
    ring - the Hann window satisfies the constant-overlap-add identity at
    50% hop, so no extra gain compensation is needed on the sum }
  for i := 0 to PS_HOP - 1 do
  begin
    wp := FRingWrite[AChannel];
    FRing[AChannel][wp] := FOlaBuf[AChannel][i];
    FRingWrite[AChannel] := (wp + 1) and (PS_RING_LEN - 1);   // PS_RING_LEN is a power of two
    if FRingCount[AChannel] < FRingLen then Inc(FRingCount[AChannel]);
  end;

  { slide the OLA accumulator left by PS_HOP for the next hop }
  Move(FOlaBuf[AChannel][PS_HOP], FOlaBuf[AChannel][0], (PS_CHUNK - PS_HOP) * SizeOf(Single));
  FillChar(FOlaBuf[AChannel][PS_CHUNK - PS_HOP], PS_HOP * SizeOf(Single), 0);

  { slide the analysis window left by PS_HOP, freeing the tail for new input }
  Move(FInWin[AChannel][PS_HOP], FInWin[AChannel][0], (PS_CHUNK - PS_HOP) * SizeOf(Single));
  FInFill[AChannel] := 0;
end;

procedure TPitchShiftNode.Reset;
var
  ch: Integer;
begin
  for ch := 0 to High(FInWin) do
  begin
    FillChar(FInWin[ch][0], Length(FInWin[ch]) * SizeOf(Single), 0);
    FillChar(FOlaBuf[ch][0], Length(FOlaBuf[ch]) * SizeOf(Single), 0);
    FillChar(FRing[ch][0], Length(FRing[ch]) * SizeOf(Single), 0);
    FInFill[ch] := 0;
    FRingRead[ch] := 0;
    FRingWrite[ch] := 0;
    FRingCount[ch] := 0;
  end;
end;

procedure TPitchShiftNode.Process(AIn, AOut: TAudioBuffer);
var
  nc, ch, i, n, rp: Integer;
  x: Single;
begin
  n := AOut.FrameCount;
  GatherPtrs(AIn, AOut, nc);
  if (nc = 0) or (n = 0) then Exit;
  if Length(FInWin) <> FChannels then EnsureAlloc;

  for ch := 0 to nc - 1 do
  begin
    for i := 0 to n - 1 do
    begin
      x := FInPtrs[ch][i];
      FInWin[ch][PS_CHUNK - PS_HOP + FInFill[ch]] := x;
      Inc(FInFill[ch]);
      if FInFill[ch] >= PS_HOP then
        RunHop(ch);
    end;

    for i := 0 to n - 1 do
    begin
      if FRingCount[ch] > 0 then
      begin
        rp := FRingRead[ch];
        FOutPtrs[ch][i] := FRing[ch][rp];
        FRingRead[ch] := (rp + 1) and (PS_RING_LEN - 1);
        Dec(FRingCount[ch]);
      end
      else
        FOutPtrs[ch][i] := 0;   { startup latency: silence until the first hop completes }
    end;
  end;
end;

function TPitchShiftNode.SerializeParams: string;
begin
  Result := 'semitones=' + FloatId(FSemitones);
end;

procedure TPitchShiftNode.DeserializeParams(const AText: string);
begin
  FSemitones := ParamFloat(AText, 'semitones', 0.0);
  if FConfigured then DoConfigure;
end;

{ ================= TBusNode ================= }

procedure TBusNode.Process(AIn, AOut: TAudioBuffer);
begin
  AOut.CopyFrom(AIn);
end;

{ ================= TOutputNode ================= }

procedure TOutputNode.DoConfigure;
begin
  FCurLin := DbToLinear(FGainDb);
end;

procedure TOutputNode.Reset;
begin
  FCurLin := DbToLinear(FGainDb);
end;

procedure TOutputNode.Process(AIn, AOut: TAudioBuffer);
var
  ch, n: Integer;
  target, glide, newLin: Double;
begin
  AOut.CopyFrom(AIn);
  n := AOut.FrameCount;
  if n <= 0 then Exit;
  target := DbToLinear(FGainDb);
  glide := n / (0.015 * FSampleRate + n);
  if glide > 1.0 then glide := 1.0;
  newLin := FCurLin + (target - FCurLin) * glide;
  if (Abs(newLin - 1.0) > 1.0E-6) or (Abs(FCurLin - 1.0) > 1.0E-6) then
    for ch := 0 to AOut.ChannelCount - 1 do
      BlockScaleRamp(PSingle(AOut.ChannelPtr(ch)), FCurLin, newLin, n);
  FCurLin := newLin;
end;

function TOutputNode.SerializeParams: string;
begin
  Result := 'db=' + FloatId(FGainDb);
end;

procedure TOutputNode.DeserializeParams(const AText: string);
begin
  FGainDb := ParamFloat(AText, 'db', 0.0);
  FCurLin := DbToLinear(FGainDb);
end;

{ ================= TVST2Node ================= }

destructor TVST2Node.Destroy;
begin
  FHost.Free;
  inherited Destroy;
end;

procedure TVST2Node.DoConfigure;
var
  path: string;
begin
  if FHost = nil then FHost := TVST2Host.Create;
  path := PluginPath;
  if path = '' then Exit;

  if (not FHost.IsLoaded) or (not SameText(FHost.Path, path)) then
  begin
    FLoadError := '';
    FPendingStateApplied := False;
    try
      FHost.LoadAndOpen(path, FSampleRate, FMaxFrames, FChannels);
    except
      on E: Exception do
      begin
        FLoadError := E.Message;
        Exit;   // stays a dry pass-through insert - see the class comment
      end;
    end;
  end
  else
    FHost.Configure(FSampleRate, FMaxFrames, FChannels);

  if (not FPendingStateApplied) and (FStateB64 <> '') then
  begin
    FHost.LoadStateBase64(FStateB64);
    FPendingStateApplied := True;
  end;
end;

procedure TVST2Node.Reset;
begin
  if (FHost <> nil) and FHost.IsLoaded then FHost.Reset;
end;

procedure TVST2Node.Process(AIn, AOut: TAudioBuffer);
var
  nc, n: Integer;
  ok: Boolean;
begin
  n := AOut.FrameCount;
  GatherPtrs(AIn, AOut, nc);
  if (nc = 0) or (n = 0) then Exit;
  ok := False;
  if (FHost <> nil) and FHost.IsLoaded then
  begin
    try
      FHost.Process(FInPtrs, FOutPtrs, n);
      ok := True;
    except
      on E: Exception do
      begin
        { a plugin that throws mid-processing (bad state, DSP fault) must
          not take the audio engine down with it: record the fault, unload
          it, and fall through to dry pass-through like a load failure }
        FLoadError := 'VST2 process fault: ' + E.Message;
        FHost.Close;
      end;
    end;
  end;
  if not ok then
  begin
    { plugin missing / failed to load or crashed while processing: honest
      dry pass-through, not silence and not a crash - see FLoadError }
    for nc := 0 to High(FOutPtrs) do
      Move(FInPtrs[nc]^, FOutPtrs[nc]^, n * SizeOf(Single));
  end;
end;

function TVST2Node.PluginPath: string;
begin
  Result := '';
  if FPathB64 = '' then Exit;
  Result := TEncoding.UTF8.GetString(TNetEncoding.Base64.DecodeStringToBytes(FPathB64));
end;

procedure TVST2Node.CaptureState;
begin
  if (FHost <> nil) and FHost.IsLoaded then
    FStateB64 := FHost.SaveStateBase64;
end;

function TVST2Node.SerializeParams: string;
begin
  { CaptureState is the caller's job (typically right before a save, from
    whatever UI has the editor open) so a plugin's live tweaking doesn't pay
    for a chunk dump on every keystroke; this just persists whatever was
    last captured (or the state the insert was loaded with). }
  Result := Format('path=%s;state=%s', [FPathB64, FStateB64]);
end;

procedure TVST2Node.DeserializeParams(const AText: string);
begin
  FPathB64 := ParamStrDef(AText, 'path', '');
  FStateB64 := ParamStrDef(AText, 'state', '');
  FPendingStateApplied := False;
  if FConfigured then DoConfigure;
end;

{ ================= TCLAPNode ================= }

destructor TCLAPNode.Destroy;
begin
  FHost.Free;
  inherited Destroy;
end;

procedure TCLAPNode.DoConfigure;
var
  path: string;
begin
  if FHost = nil then FHost := TCLAPHost.Create;
  path := PluginPath;
  if path = '' then Exit;

  if (not FHost.IsLoaded) or (not SameText(FHost.Path, path)) then
  begin
    FLoadError := '';
    FPendingStateApplied := False;
    try
      FHost.LoadAndOpen(path, FSampleRate, FMaxFrames, FChannels);
    except
      on E: Exception do
      begin
        FLoadError := E.Message;
        Exit;   // stays a dry pass-through insert - see the class comment
      end;
    end;
  end
  else
    FHost.Configure(FSampleRate, FMaxFrames, FChannels);

  if (not FPendingStateApplied) and (FStateB64 <> '') then
  begin
    FHost.LoadStateBase64(FStateB64);
    FPendingStateApplied := True;
  end;
end;

procedure TCLAPNode.Reset;
begin
  if (FHost <> nil) and FHost.IsLoaded then FHost.Reset;
end;

procedure TCLAPNode.Process(AIn, AOut: TAudioBuffer);
var
  nc, n: Integer;
  ok: Boolean;
begin
  n := AOut.FrameCount;
  GatherPtrs(AIn, AOut, nc);
  if (nc = 0) or (n = 0) then Exit;
  ok := False;
  if (FHost <> nil) and FHost.IsLoaded then
  begin
    try
      FHost.Process(FInPtrs, FOutPtrs, n);
      ok := True;
    except
      on E: Exception do
      begin
        { a plugin that throws mid-processing (bad state, DSP fault) must
          not take the audio engine down with it: record the fault, unload
          it, and fall through to dry pass-through like a load failure }
        FLoadError := 'CLAP process fault: ' + E.Message;
        FHost.Close;
      end;
    end;
  end;
  if not ok then
  begin
    { plugin missing / failed to load or crashed while processing: honest
      dry pass-through, not silence and not a crash - see FLoadError }
    for nc := 0 to High(FOutPtrs) do
      Move(FInPtrs[nc]^, FOutPtrs[nc]^, n * SizeOf(Single));
  end;
end;

function TCLAPNode.PluginPath: string;
begin
  Result := '';
  if FPathB64 = '' then Exit;
  Result := TEncoding.UTF8.GetString(TNetEncoding.Base64.DecodeStringToBytes(FPathB64));
end;

procedure TCLAPNode.CaptureState;
begin
  if (FHost <> nil) and FHost.IsLoaded then
    FStateB64 := FHost.SaveStateBase64;
end;

function TCLAPNode.SerializeParams: string;
begin
  { CaptureState is the caller's job (typically right before a save, from
    whatever UI has the editor open) so a plugin's live tweaking doesn't pay
    for a chunk dump on every keystroke; this just persists whatever was
    last captured (or the state the insert was loaded with). }
  Result := Format('path=%s;state=%s', [FPathB64, FStateB64]);
end;

procedure TCLAPNode.DeserializeParams(const AText: string);
begin
  FPathB64 := ParamStrDef(AText, 'path', '');
  FStateB64 := ParamStrDef(AText, 'state', '');
  FPendingStateApplied := False;
  if FConfigured then DoConfigure;
end;

{ ================= TVST3Node ================= }

destructor TVST3Node.Destroy;
begin
  FHost.Free;
  inherited Destroy;
end;

procedure TVST3Node.DoConfigure;
var
  path: string;
begin
  if FHost = nil then FHost := TVST3Host.Create;
  path := PluginPath;
  if path = '' then Exit;

  if (not FHost.IsLoaded) or (not SameText(FHost.Path, path)) then
  begin
    FLoadError := '';
    FPendingStateApplied := False;
    try
      FHost.LoadAndOpen(path, FSampleRate, FMaxFrames, FChannels);
    except
      on E: Exception do
      begin
        FLoadError := E.Message;
        Exit;   // stays a dry pass-through insert - see the class comment
      end;
    end;
  end
  else
    FHost.Configure(FSampleRate, FMaxFrames, FChannels);

  if (not FPendingStateApplied) and (FStateB64 <> '') then
  begin
    FHost.LoadStateBase64(FStateB64);
    FPendingStateApplied := True;
  end;
end;

procedure TVST3Node.Reset;
begin
  if (FHost <> nil) and FHost.IsLoaded then FHost.Reset;
end;

procedure TVST3Node.Process(AIn, AOut: TAudioBuffer);
var
  nc, n: Integer;
  ok: Boolean;
begin
  n := AOut.FrameCount;
  GatherPtrs(AIn, AOut, nc);
  if (nc = 0) or (n = 0) then Exit;
  ok := False;
  if (FHost <> nil) and FHost.IsLoaded then
  begin
    try
      FHost.Process(FInPtrs, FOutPtrs, n);
      ok := True;
    except
      on E: Exception do
      begin
        { a plugin that throws mid-processing (bad state, DSP fault) must
          not take the audio engine down with it: record the fault, unload
          it, and fall through to dry pass-through like a load failure }
        FLoadError := 'VST3 process fault: ' + E.Message;
        FHost.Close;
      end;
    end;
  end;
  if not ok then
  begin
    { plugin missing / failed to load or crashed while processing: honest
      dry pass-through, not silence and not a crash - see FLoadError }
    for nc := 0 to High(FOutPtrs) do
      Move(FInPtrs[nc]^, FOutPtrs[nc]^, n * SizeOf(Single));
  end;
end;

function TVST3Node.PluginPath: string;
begin
  Result := '';
  if FPathB64 = '' then Exit;
  Result := TEncoding.UTF8.GetString(TNetEncoding.Base64.DecodeStringToBytes(FPathB64));
end;

procedure TVST3Node.CaptureState;
begin
  if (FHost <> nil) and FHost.IsLoaded then
    FStateB64 := FHost.SaveStateBase64;
end;

function TVST3Node.SerializeParams: string;
begin
  { CaptureState is the caller's job (typically right before a save, from
    whatever UI has the editor open) so a plugin's live tweaking doesn't pay
    for a chunk dump on every keystroke; this just persists whatever was
    last captured (or the state the insert was loaded with). }
  Result := Format('path=%s;state=%s', [FPathB64, FStateB64]);
end;

procedure TVST3Node.DeserializeParams(const AText: string);
begin
  FPathB64 := ParamStrDef(AText, 'path', '');
  FStateB64 := ParamStrDef(AText, 'state', '');
  FPendingStateApplied := False;
  if FConfigured then DoConfigure;
end;

{ ================= TPythonNode ================= }

destructor TPythonNode.Destroy;
begin
  DropHost;
  inherited Destroy;
end;

procedure TPythonNode.DropHost;
begin
  if FHost = nil then Exit;
  PyLive.Unregister(FIid, FHost);
  FHost.AudioActive := False;
  FHost.Release;
  FHost := nil;
  FStartedKey := '';
end;

{ what a running instance depends on: a change in any of these needs a fresh process }
function TPythonNode.ConfigKey: string;
begin
  Result := Format('%s|%s|%s|%d|%d|%d', [FPathB64, PyScriptStamp(PyDecode(FPathB64)), FSrcB64, FSampleRate, FChannels, FMaxFrames]);
end;

procedure TPythonNode.DoConfigure;
var
  src, err, key, fileName, scriptDir: string;
  v: TJSONValue;
  pair: TJSONPair;
begin
  if (FPathB64 = '') and (FSrcB64 = '') then Exit;
  key := ConfigKey;
  if (FHost <> nil) and (FHost.Dead or (FStartedKey <> key)) then DropHost;
  if FHost = nil then
  begin
    if FFailedKey = key then Exit;            // already tried this exact setup: stay dry
    if not PyInsertSource(Format('path=%s;src=%s;file=%s', [FPathB64, FSrcB64, FFileB64]),
         src, fileName, scriptDir, err) then
    begin
      FLoadError := err;
      FFailedKey := key;
      Exit;
    end;
    FHost := TPyPluginHost.Create;
    if not FHost.Start(src, fileName, scriptDir, PyDecode(FValsB64), PyDecode(FStateB64),
         FSampleRate, FChannels, FMaxFrames, err) then
    begin
      FLoadError := err;
      FHost.Release;
      FHost := nil;
      FFailedKey := key;
      Exit;
    end;
    FLoadError := '';
    FFailedKey := '';
    FStartedKey := key;
    FHost.AudioActive := True;
    PyLive.Register(FIid, FHost);
  end
  else if FValsB64 <> '' then
  begin
    { same script, new settings (an edit or an undo in the project): move the parameters }
    v := TJSONObject.ParseJSONValue(PyDecode(FValsB64));
    try
      if v is TJSONObject then
        for pair in TJSONObject(v) do
          if pair.JsonValue is TJSONNumber then
            FHost.SetParam(pair.JsonString.Value, TJSONNumber(pair.JsonValue).AsDouble);
    finally
      v.Free;
    end;
  end;
end;

procedure TPythonNode.Reset;
begin
  if (FHost <> nil) and FHost.Ready then FHost.ResetDsp;
end;

procedure TPythonNode.Process(AIn, AOut: TAudioBuffer);
var
  nc, n: Integer;
  ok: Boolean;
begin
  n := AOut.FrameCount;
  GatherPtrs(AIn, AOut, nc);
  if (nc = 0) or (n = 0) then Exit;
  ok := (FHost <> nil) and FHost.ProcessBlock(FInPtrs, FOutPtrs, n);
  if not ok then
    { script missing / slow / stopped: the dry signal, never silence and never a stall }
    for nc := 0 to High(FOutPtrs) do
      Move(FInPtrs[nc]^, FOutPtrs[nc]^, n * SizeOf(Single));
end;

function TPythonNode.SerializeParams: string;
begin
  Result := Format('path=%s;src=%s;vals=%s;state=%s;iid=%s;file=%s;pn=%s',
    [FPathB64, FSrcB64, FValsB64, FStateB64, FIid, FFileB64, FNamesB64]);
end;

procedure TPythonNode.DeserializeParams(const AText: string);
var
  newIid: string;
begin
  FSrcB64 := ParamStrDef(AText, 'src', '');
  FPathB64 := ParamStrDef(AText, 'path', '');
  FValsB64 := ParamStrDef(AText, 'vals', '');
  FStateB64 := ParamStrDef(AText, 'state', '');
  FFileB64 := ParamStrDef(AText, 'file', '');
  FNamesB64 := ParamStrDef(AText, 'pn', '');
  newIid := ParamStrDef(AText, 'iid', '');
  if (newIid <> FIid) and (FHost <> nil) then DropHost;
  FIid := newIid;
  if FConfigured then DoConfigure;
end;

{ ================= factory ================= }

function CreateNode(AId: Integer; AKind: TNodeKind; const AName: string): TAudioNode;
begin
  case AKind of
    nkInput:       Result := TInputNode.Create(AId, AKind, AName);
    nkSource:      Result := TGraphSourceNode.Create(AId, AKind, AName);
    nkGain:        Result := TGainNode.Create(AId, AKind, AName);
    nkPan:         Result := TPanNode.Create(AId, AKind, AName);
    nkBiquad:      Result := TBiquadNode.Create(AId, AKind, AName);
    nkFilterChain: Result := TFilterChainNode.Create(AId, AKind, AName);
    nkDCBlock:     Result := TDCBlockNode.Create(AId, AKind, AName);
    nkDelay:       Result := TDelayNode.Create(AId, AKind, AName);
    nkChannelMap:  Result := TChannelMapNode.Create(AId, AKind, AName);
    nkMeter:       Result := TMeterNode.Create(AId, AKind, AName);
    nkCompressor:  Result := TCompressorNode.Create(AId, AKind, AName);
    nkModulation:  Result := TModulationNode.Create(AId, AKind, AName);
    nkDistortion:  Result := TDistortionNode.Create(AId, AKind, AName);
    nkReverb:      Result := TReverbNode.Create(AId, AKind, AName);
    nkGraphicEQ:   Result := TGraphicEQNode.Create(AId, AKind, AName);
    nkMultibandComp: Result := TMultibandCompNode.Create(AId, AKind, AName);
    nkMastering:   Result := TMasteringNode.Create(AId, AKind, AName);
    nkScope:       Result := TScopeNode.Create(AId, AKind, AName);
    nkVST2:        Result := TVST2Node.Create(AId, AKind, AName);
    nkCLAP:        Result := TCLAPNode.Create(AId, AKind, AName);
    nkVST3:        Result := TVST3Node.Create(AId, AKind, AName);
    nkPython:      Result := TPythonNode.Create(AId, AKind, AName);
    nkParametricEQ: Result := TParametricEQNode.Create(AId, AKind, AName);
    nkStereoWidth: Result := TStereoWidthNode.Create(AId, AKind, AName);
    nkTransientShaper: Result := TTransientShaperNode.Create(AId, AKind, AName);
    nkExciter:     Result := TExciterNode.Create(AId, AKind, AName);
    nkPitchShift:  Result := TPitchShiftNode.Create(AId, AKind, AName);
    nkLookaheadLimiter: Result := TLookaheadLimiterNode.Create(AId, AKind, AName);
    nkBus:         Result := TBusNode.Create(AId, AKind, AName);
    nkOutput:      Result := TOutputNode.Create(AId, AKind, AName);
  else
    RaiseUDAWFmt(errInvalidArgument, GRAPH_SUBSYS,
      'CreateNode: unknown node kind %d', [Ord(AKind)]);
    Result := nil;
  end;
end;

end.
