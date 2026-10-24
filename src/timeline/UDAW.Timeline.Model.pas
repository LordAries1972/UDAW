unit UDAW.Timeline.Model;
{$I udaw.inc}

{ Phase 7 - Timeline: the in-memory arrangement model (plan section 7).

  TTimeline owns an ordered list of TTimelineTrack; each track owns an ordered
  list of TTimelineClip. A clip is a NON-DESTRUCTIVE reference into a
  TMediaSource (registered once per file on the timeline, so two clips of the
  same file share one entry and one waveform cache): it stores where the source
  begins to play (SourceOffsetSeconds), how long the window is (LengthSeconds),
  and where it sits on the timeline (StartSeconds), plus per-clip gain, fades,
  reverse, mute and lock. No clip operation ever alters source audio - split,
  trim, slip and crop only move the window.

  All positions are in seconds (see UDAW.Timeline.Time for conversions). The
  model has no GUI or audio-engine dependency; the editor view and the render
  path consume it. Undo/redo lives in UDAW.Timeline.Commands. }

interface

uses
  SysUtils, Classes, Math, StrUtils, Generics.Collections,
  UDAW.Errors,
  UDAW.Timeline.Time,
  UDAW.Timeline.Waveform;

const
  TIMELINE_MODEL_SUBSYS = 'Timeline.Model';

  { Smallest clip / fade we allow, to keep zero-length artefacts out. }
  TIMELINE_MIN_CLIP_SECONDS = 1.0E-6;

  { Left track-header column width (see TTimeline.HeaderWidth): default and
    the range a user's drag-resize (see UDAW.UI.MainForm's pbTimeline mouse
    handlers) is clamped to - wide enough for a track name, never so narrow
    the lane area vanishes or so wide it swallows the whole viewport. }
  TIMELINE_HEADER_WIDTH_DEFAULT = 230;
  TIMELINE_HEADER_WIDTH_MIN = 190;   // room for the avatar, name, M / S / R, volume and pan
  TIMELINE_HEADER_WIDTH_MAX = 400;

type
  TTrackKind = (
    tkAudio, tkMidi, tkInstrument, tkTracker, tkBus, tkAux, tkFolder, tkMaster, tkVideo);

  TFadeShape = (fsLinear, fsEqualPower, fsLogarithmic);

  TMediaKind = (mkAudioFile, mkGenerated, mkVideoFile);

  { A registered source media reference. Owns an optional waveform cache that
    is built lazily (EnsureWaveform) and shared by every clip that uses it. }
  TMediaSource = class
  private
    FId: Integer;
    FKind: TMediaKind;
    FPath: string;
    FSampleRate: Integer;
    FChannels: Integer;
    FFrameCount: Int64;
    FWaveform: TWaveformCache;
  public
    constructor Create(AId: Integer; const APath: string;
      ASampleRate, AChannels: Integer; AFrameCount: Int64;
      AKind: TMediaKind = mkAudioFile);
    destructor Destroy; override;

    function DurationSeconds: Double;
    { Builds the waveform cache from the file on first call (no-op afterwards).
      Safe to call with a missing file - it just leaves Waveform nil. }
    procedure EnsureWaveform(AOnProgress: TWaveformProgressEvent = nil);
    procedure AttachWaveform(ACache: TWaveformCache);  // takes ownership

    property Id: Integer read FId;
    property Kind: TMediaKind read FKind;
    property Path: string read FPath;
    property SampleRate: Integer read FSampleRate;
    property Channels: Integer read FChannels;
    property FrameCount: Int64 read FFrameCount;
    property Waveform: TWaveformCache read FWaveform;
  end;

  { One rendered-effect region on a clip; a clip keeps every one applied, so a
    later selection never replaces an earlier one. }
  TClipEffectRegion = record
    Name: string;
    OffsetSeconds: Double;   // from the clip's start
    LengthSeconds: Double;   // 0 = to the end of the clip
    Color: Integer;
    Kind: string;            // effect kind it was rendered with ('' = unknown/older project)
    Params: string;          // the settings it was rendered with, so it can be edited later
  end;

  TTimelineClip = class
  private
    FEffectRegions: TArray<TClipEffectRegion>;
    FId: Integer;
    FName: string;
    FSourceId: Integer;
    FStartSeconds: Double;
    FSourceOffsetSeconds: Double;
    FLengthSeconds: Double;
    FGainDb: Double;
    FFadeInSeconds: Double;
    FFadeOutSeconds: Double;
    FFadeInShape: TFadeShape;
    FFadeOutShape: TFadeShape;
    FReversed: Boolean;
    FMuted: Boolean;
    FLocked: Boolean;
    FLoop: Boolean;
    FColor: Integer;
    FEffectName: string;
    FEffectOffsetSeconds: Double;
    FEffectLengthSeconds: Double;
    FSourceBPM: Double;
    FHasOrig: Boolean;
    FOrigSourceId: Integer;
    FOrigDelta: Double;
    procedure ClampFades;
  public
    { Pre-effect audio: the source the clip pointed at before its first
      rendered effect, and (original source time) - (current source time) at
      any timeline point; the delta stays valid across trims/splits. Lets
      "Restore Original" put the untouched sound back over a range. }
    property HasOrig: Boolean read FHasOrig write FHasOrig;
    property OrigSourceId: Integer read FOrigSourceId write FOrigSourceId;
    property OrigDelta: Double read FOrigDelta write FOrigDelta;
    constructor Create(AId: Integer);
    procedure Assign(ASrc: TTimelineClip);
    function Clone: TTimelineClip;
    procedure AddEffectRegion(const AName: string; AOffset, ALength: Double; AColor: Integer;
      const AKind: string = ''; const AParams: string = '');
    { Keeps only the effect regions (and the legacy single EffectName span)
      inside [AFrom, ATo) - seconds from the clip's current start - clipped
      to that window and rebased so offsets count from AFrom. Called with the
      clip's pre-edit length when a clip is split or sliced, so each piece
      carries exactly the effects that lie inside it. }
    procedure KeepEffectsWithin(AFrom, ATo: Double);
    property EffectRegions: TArray<TClipEffectRegion> read FEffectRegions write FEffectRegions;

    function EndSeconds: Double;
    function ContainsSeconds(ASeconds: Double): Boolean;
    function HasEffects: Boolean;
    { Phase 38 - MIDI Timeline clips: a clip with SourceId < 0 references a
      TMidiProject clip by stable Id (-SourceId), not a TMediaSource - see
      EncodeMidiSourceId/DecodeMidiSourceId below. AddClip/AddClipWithId
      never look SourceId up in FSources when it is negative, so this needs
      no separate storage or serialization change: the existing SourceId
      column already round-trips signed integers. }
    function IsMidiClip: Boolean;
    function MidiClipId: Integer;   // 0 when IsMidiClip is False
    { Gain multiplier at a timeline position, folding in the fades (1.0 in the
      body, 0.0 outside the clip, shaped ramp inside a fade). }
    function GainAt(ASeconds: Double): Double;
    { Where in the source, in seconds, timeline position ASeconds reads from -
      honouring Reversed. Undefined outside [StartSeconds, EndSeconds]. }
    function SourceSecondsAt(ASeconds: Double): Double;
    { Tempo conform factor (output length / input length) for a clip that
      carries a SourceBPM, against the Timeline tempo AStretchBPM - the same
      rule the audio player applies (outside 0.25..4 or ~1.0 means 1.0). }
    function ConformFactor(AStretchBPM: Double): Double;
    { Source position for a VIDEO clip at timeline position ASeconds: honours
      Reversed and the tempo conform, matching what the audio of the same clip
      does. }
    function VideoSourceSecondsAt(ASeconds, AStretchBPM: Double): Double;

    property Id: Integer read FId;
    property Name: string read FName write FName;
    property SourceId: Integer read FSourceId write FSourceId;
    property StartSeconds: Double read FStartSeconds write FStartSeconds;
    property SourceOffsetSeconds: Double read FSourceOffsetSeconds write FSourceOffsetSeconds;
    property LengthSeconds: Double read FLengthSeconds write FLengthSeconds;
    property GainDb: Double read FGainDb write FGainDb;
    property FadeInSeconds: Double read FFadeInSeconds write FFadeInSeconds;
    property FadeOutSeconds: Double read FFadeOutSeconds write FFadeOutSeconds;
    property FadeInShape: TFadeShape read FFadeInShape write FFadeInShape;
    property FadeOutShape: TFadeShape read FFadeOutShape write FFadeOutShape;
    property Reversed: Boolean read FReversed write FReversed;
    property Muted: Boolean read FMuted write FMuted;
    property Locked: Boolean read FLocked write FLocked;
    property Loop: Boolean read FLoop write FLoop;
    property Color: Integer read FColor write FColor;
    { Name of the last DSP effect rendered onto this clip (see
      TfrmMain.TlApplyEffectToRange / TlApplySilenceToRange) - drives the
      per-effect colour on the clip's title strip and the label shown at the
      clip's own start (region start point), not a fixed screen position, so
      it scrolls with the timeline exactly like the clip it names. Empty when
      no effect has been rendered onto the clip. }
    property EffectName: string read FEffectName write FEffectName;
    { Where the effect region starts, in seconds from the clip's start - the
      Timeline draws the effect's name there, not at the clip's own start. }
    property EffectOffsetSeconds: Double read FEffectOffsetSeconds write FEffectOffsetSeconds;
    { Length of the effect region; 0 = to the end of the clip (older projects).
      Only this span is drawn in the effect's colour. }
    property EffectLengthSeconds: Double read FEffectLengthSeconds write FEffectLengthSeconds;
    { Tempo the clip's audio was recorded at (0 = unknown/off). When > 0,
      playback and export time-stretch the clip (pitch preserved) by
      SourceBPM / project tempo so it plays at the Timeline BPM whatever the
      file's own speed. The clip's timeline length is unchanged. }
    property SourceBPM: Double read FSourceBPM write FSourceBPM;
  end;

  TTimelineTrack = class
  private
    FId: Integer;
    FKind: TTrackKind;
    FName: string;
    FColor: Integer;
    FHeight: Integer;
    FMuted: Boolean;
    FSoloed: Boolean;
    FArmed: Boolean;
    FGainDb: Double;
    FPan: Double;
    FTitle: string;
    FClips: TObjectList<TTimelineClip>;
  public
    constructor Create(AId: Integer; AKind: TTrackKind; const AName: string);
    destructor Destroy; override;

    procedure SortClips;
    function AddClip(AClip: TTimelineClip): TTimelineClip;   // takes ownership, keeps sorted
    function ExtractClip(AClipId: Integer): TTimelineClip;    // caller owns result
    procedure RemoveClip(AClipId: Integer);
    function ClipById(AClipId: Integer): TTimelineClip;
    function IndexOfClip(AClipId: Integer): Integer;
    function ClipAtSeconds(ASeconds: Double): TTimelineClip;
    { the looping clip (Loop set) that has already ended before ASeconds but is still repeating: it
      fills the lane until ALimit (the end of the last segment on the Timeline) }
    function LoopFillClipAt(ASeconds, ALimit: Double): TTimelineClip;  // first overlapping
    function ClipCount: Integer;
    function GetClip(AIndex: Integer): TTimelineClip;
    function LastEndSeconds: Double;

    property Id: Integer read FId;
    property Kind: TTrackKind read FKind write FKind;
    property Name: string read FName write FName;
    property Color: Integer read FColor write FColor;
    property Height: Integer read FHeight write FHeight;
    property Muted: Boolean read FMuted write FMuted;
    property Soloed: Boolean read FSoloed write FSoloed;
    property Armed: Boolean read FArmed write FArmed;
    property GainDb: Double read FGainDb write FGainDb;
    property Pan: Double read FPan write FPan;
    { section/effect-name title shown on this track's own title band, just
      above its header/lane content (see pbTimelinePaint) - a per-channel
      annotation, distinct from the timeline-wide Markers. Effect inserts
      added to this track append their name here automatically. }
    property Title: string read FTitle write FTitle;
  end;

  { one chord of the Chords lane: a symbol such as "Am7" held over a span }
  TTimelineChord = class
  private
    FId: Integer;
    FName: string;
    FStartSeconds: Double;
    FLengthSeconds: Double;
    FLocked: Boolean;
  public
    constructor Create(AId: Integer; const AName: string; AStart, ALength: Double);
    function EndSeconds: Double;
    property Id: Integer read FId;
    property Name: string read FName write FName;
    property StartSeconds: Double read FStartSeconds write FStartSeconds;
    property LengthSeconds: Double read FLengthSeconds write FLengthSeconds;
    { locked: it cannot be moved until it is unlocked }
    property Locked: Boolean read FLocked write FLocked;
  end;

  TTimelineMarker = class
  private
    FId: Integer;
    FName: string;
    FSeconds: Double;
    FLocked: Boolean;
  public
    constructor Create(AId: Integer; const AName: string; ASeconds: Double);
    property Id: Integer read FId;
    property Name: string read FName write FName;
    property Seconds: Double read FSeconds write FSeconds;
    { locked: it cannot be moved until it is unlocked }
    property Locked: Boolean read FLocked write FLocked;
  end;

  TTimelineRegion = class
  private
    FId: Integer;
    FName: string;
    FStartSeconds: Double;
    FLengthSeconds: Double;
    FColor: Integer;
    FContinuous: Boolean;
    FLocked: Boolean;
  public
    constructor Create(AId: Integer; const AName: string; AStart, ALength: Double);
    function EndSeconds: Double;
    property Id: Integer read FId;
    property Name: string read FName write FName;
    { a launched scene plays its region once and then stops, unless this is set: then it loops on and on }
    property Continuous: Boolean read FContinuous write FContinuous;
    property StartSeconds: Double read FStartSeconds write FStartSeconds;
    property LengthSeconds: Double read FLengthSeconds write FLengthSeconds;
    property Color: Integer read FColor write FColor;
    { locked: it cannot be moved until it is unlocked }
    property Locked: Boolean read FLocked write FLocked;
  end;

  { A video effect or transition laid over a span of one video track (see
    UDAW.Video.Effects). A transition region sits across the cut between two
    clips; PivotSeconds is that cut (the outgoing clip is held on its last
    picture after it, the incoming one on its first picture before it). }
  TVideoEffectRegion = class
  private
    FId: Integer;
    FTrackId: Integer;
    FKind: string;
    FName: string;
    FStartSeconds: Double;
    FLengthSeconds: Double;
    FPivotSeconds: Double;
    FParams: string;
  public
    constructor Create(AId, ATrackId: Integer; const AKind, AName: string;
      AStart, ALength, APivot: Double; const AParams: string);
    function EndSeconds: Double;
    property Id: Integer read FId;
    property TrackId: Integer read FTrackId;
    property Kind: string read FKind;
    property Name: string read FName;
    property StartSeconds: Double read FStartSeconds write FStartSeconds;
    property LengthSeconds: Double read FLengthSeconds write FLengthSeconds;
    property PivotSeconds: Double read FPivotSeconds write FPivotSeconds;
    property Params: string read FParams write FParams;
  end;

  TClipEdge = (ceStart, ceEnd);

  TTimeline = class
  private
    FVideoFx: TObjectList<TVideoEffectRegion>;
    FNextVideoFxId: Integer;
    FTracks: TObjectList<TTimelineTrack>;
    FSources: TObjectList<TMediaSource>;
    FMarkers: TObjectList<TTimelineMarker>;
    FChords: TObjectList<TTimelineChord>;
    FNextChordId: Integer;
    FRegions: TObjectList<TTimelineRegion>;
    FNextTrackId: Integer;
    FNextClipId: Integer;
    FNextSourceId: Integer;
    FNextMarkerId: Integer;
    FNextRegionId: Integer;
    FPlayheadSeconds: Double;
    FLoopStartSeconds: Double;
    FLoopLengthSeconds: Double;
    FLoopEnabled: Boolean;
    FMasterVolumeDb: Double;
    FHeaderWidth: Integer;
    procedure SetMasterVolumeDb(AValue: Double);
    procedure SetHeaderWidth(AValue: Integer);
    function FindTrackOfClip(AClipId: Integer): TTimelineTrack;
    procedure GuardUnlocked(AClip: TTimelineClip);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    function Clone: TTimeline;

    { ---- id-allocation control (used by deserializer / commands for stable ids) ---- }
    procedure BumpTrackId(AObservedId: Integer);
    procedure BumpClipId(AObservedId: Integer);
    procedure BumpSourceId(AObservedId: Integer);
    procedure BumpMarkerId(AObservedId: Integer);
    procedure BumpRegionId(AObservedId: Integer);

    { ---- sources ---- }
    function AddSource(const APath: string; ASampleRate, AChannels: Integer;
      AFrameCount: Int64; AKind: TMediaKind = mkAudioFile): TMediaSource;
    function AddSourceWithId(AId: Integer; const APath: string;
      ASampleRate, AChannels: Integer; AFrameCount: Int64;
      AKind: TMediaKind = mkAudioFile): TMediaSource;
    function SourceById(AId: Integer): TMediaSource;
    function SourceCount: Integer;
    function GetSource(AIndex: Integer): TMediaSource;
    function SourceUseCount(ASourceId: Integer): Integer;
    procedure RemoveUnusedSources;

    { ---- tracks ---- }
    function AddTrack(AKind: TTrackKind; const AName: string): TTimelineTrack;
    function AddTrackWithId(AId: Integer; AKind: TTrackKind; const AName: string): TTimelineTrack;
    procedure RemoveTrack(ATrackId: Integer);
    procedure MoveTrack(ATrackId, ANewIndex: Integer);
    function TrackById(AId: Integer): TTimelineTrack;
    function IndexOfTrack(ATrackId: Integer): Integer;
    function TrackCount: Integer;
    function GetTrack(AIndex: Integer): TTimelineTrack;

    { ---- clips (all non-destructive) ---- }
    function AddClip(ATrackId: Integer; ASourceId: Integer; AName: string;
      AStartSeconds, ASourceOffsetSeconds, ALengthSeconds: Double): TTimelineClip;
    function AddClipWithId(AClipId, ATrackId, ASourceId: Integer; AName: string;
      AStartSeconds, ASourceOffsetSeconds, ALengthSeconds: Double): TTimelineClip;
    procedure RemoveClip(AClipId: Integer);
    function ClipById(AClipId: Integer; out ATrack: TTimelineTrack): TTimelineClip; overload;
    function ClipById(AClipId: Integer): TTimelineClip; overload;

    procedure MoveClip(AClipId: Integer; ANewStartSeconds: Double); overload;
    procedure MoveClip(AClipId: Integer; ANewStartSeconds: Double; ANewTrackId: Integer); overload;
    { Split AClipId at timeline position ASeconds. The left clip keeps AClipId
      and shrinks; a new right clip is created (ANewClipId, or a fresh id when
      ANewClipId <= 0) that continues into the source seamlessly. Returns the
      new right-hand clip. }
    function SplitClip(AClipId: Integer; ASeconds: Double; ANewClipId: Integer = 0): TTimelineClip;
    { Drag a clip edge. ceStart moves StartSeconds + SourceOffset together
      (the content stays put); ceEnd only changes LengthSeconds (crop). }
    procedure TrimClip(AClipId: Integer; AEdge: TClipEdge; ANewSeconds: Double);
    { Slip the content under a fixed window. }
    procedure SlipClip(AClipId: Integer; ADeltaSeconds: Double);
    { Copy placed immediately after the original on the same track. }
    function DuplicateClip(AClipId: Integer; ANewClipId: Integer = 0): TTimelineClip;

    procedure SetClipGain(AClipId: Integer; AGainDb: Double);
    { Repoints a clip at a different source and offset into it - the model
      mutation behind an offline effect render (see UDAW.UI.MainForm's
      TlApplyEffectToRange): the effect is rendered to a brand new WAV file
      registered as a new TMediaSource, and this is what swaps the clip over
      to it. LengthSeconds is left untouched by design - callers render
      exactly LengthSeconds worth of audio so the clip's timeline placement
      never moves. }
    procedure SetClipSource(AClipId: Integer; ANewSourceId: Integer; ANewSourceOffsetSeconds: Double);
    procedure SetClipFades(AClipId: Integer; AFadeInSeconds, AFadeOutSeconds: Double);
    procedure SetClipReversed(AClipId: Integer; AReversed: Boolean);
    procedure SetClipMuted(AClipId: Integer; AMuted: Boolean);
    procedure SetClipLocked(AClipId: Integer; ALocked: Boolean);

    { ---- chords (the Chords lane; edited through TSetTimelineChordsCommand) ---- }
    function AddChord(const AName: string; AStart, ALength: Double): TTimelineChord;
    function AddChordWithId(AId: Integer; const AName: string; AStart, ALength: Double): TTimelineChord;
    procedure RemoveChord(AId: Integer);
    function ChordCount: Integer;
    function GetChord(AIndex: Integer): TTimelineChord;
    function ChordById(AId: Integer): TTimelineChord;
    { the chord sounding at ASeconds, nil when none }
    function ChordAt(ASeconds: Double): TTimelineChord;
    { whole-lane text snapshot / restore, what the undo command swaps }
    function ChordsSnapshot: string;
    procedure RestoreChords(const ASnapshot: string);

    { ---- markers / regions ---- }
    function AddMarker(const AName: string; ASeconds: Double): TTimelineMarker;
    function AddMarkerWithId(AId: Integer; const AName: string; ASeconds: Double): TTimelineMarker;
    procedure RemoveMarker(AId: Integer);
    function MarkerCount: Integer;
    function GetMarker(AIndex: Integer): TTimelineMarker;
    function AddRegion(const AName: string; AStart, ALength: Double): TTimelineRegion;
    function AddRegionWithId(AId: Integer; const AName: string; AStart, ALength: Double): TTimelineRegion;
    procedure RemoveRegion(AId: Integer);
    function RegionCount: Integer;
    function GetRegion(AIndex: Integer): TTimelineRegion;

    { ---- video effects (undoable through TAddVideoEffectCommand) ---- }
    function AddVideoEffect(ATrackId: Integer; const AKind, AName: string;
      AStart, ALength, APivot: Double; const AParams: string): TVideoEffectRegion;
    function AddVideoEffectWithId(AId, ATrackId: Integer; const AKind, AName: string;
      AStart, ALength, APivot: Double; const AParams: string): TVideoEffectRegion;
    procedure RemoveVideoEffect(AId: Integer);
    function VideoEffectCount: Integer;
    function GetVideoEffect(AIndex: Integer): TVideoEffectRegion;
    function VideoEffectById(AId: Integer): TVideoEffectRegion;
    procedure BumpVideoEffectId(AObservedId: Integer);

    { ---- queries ---- }
    function TotalDurationSeconds: Double;
    function LastClipEndSeconds: Double;
    function ClipCountTotal: Integer;
    function Describe: string;

    property PlayheadSeconds: Double read FPlayheadSeconds write FPlayheadSeconds;
    property LoopStartSeconds: Double read FLoopStartSeconds write FLoopStartSeconds;
    property LoopLengthSeconds: Double read FLoopLengthSeconds write FLoopLengthSeconds;
    property LoopEnabled: Boolean read FLoopEnabled write FLoopEnabled;
    { Overall Timeline-tab playback output level - independent of, and applied
      on top of, the Mixer's own master strip fader (TTimelinePlayer renders
      tracks/clips directly, without going through TMixerProcessor - see
      UDAW.Timeline.Playback's header comment). -60..+12 dB, same range as a
      normal fader. }
    property MasterVolumeDb: Double read FMasterVolumeDb write SetMasterVolumeDb;
    { Width, in pixels, of the Timeline tab's left track-header column.
      Pure UI/view state, but persisted per-project (see UDAW.Timeline.
      Serialization) so a project reopens with its header panel the size
      it was left at. Clamped to a usable range. }
    property HeaderWidth: Integer read FHeaderWidth write SetHeaderWidth;
  end;

function TrackKindId(AKind: TTrackKind): string;
function TrackKindFromId(const AId: string; out AKind: TTrackKind): Boolean;
function TrackKindDisplay(AKind: TTrackKind): string;
function FadeShapeId(AShape: TFadeShape): string;
function ShapeRamp(AShape: TFadeShape; T: Double): Double;
function FadeShapeFromId(const AId: string; out AShape: TFadeShape): Boolean;
function DefaultTrackHeight(AKind: TTrackKind): Integer;

{ Phase 38 - MIDI Timeline clips: see TTimelineClip.IsMidiClip's comment. }
function EncodeMidiSourceId(AMidiClipId: Integer): Integer;
function DecodeMidiSourceId(ASourceId: Integer): Integer;

implementation


uses
  UDAW.DSP.MathTables;

const
  TRACK_KIND_IDS: array[TTrackKind] of string = (
    'audio', 'midi', 'instrument', 'tracker', 'bus', 'aux', 'folder', 'master', 'video');
  TRACK_KIND_DISPLAY: array[TTrackKind] of string = (
    'Audio', 'MIDI', 'Instrument', 'Tracker', 'Bus', 'Auxiliary', 'Folder', 'Master', 'VIDEO');
  FADE_SHAPE_IDS: array[TFadeShape] of string = ('lin', 'eqp', 'log');

function TrackKindId(AKind: TTrackKind): string;
begin
  Result := TRACK_KIND_IDS[AKind];
end;

function TrackKindFromId(const AId: string; out AKind: TTrackKind): Boolean;
var
  k: TTrackKind;
begin
  for k := Low(TTrackKind) to High(TTrackKind) do
    if SameText(AId, TRACK_KIND_IDS[k]) then
    begin
      AKind := k;
      Exit(True);
    end;
  Result := False;
end;

function TrackKindDisplay(AKind: TTrackKind): string;
begin
  Result := TRACK_KIND_DISPLAY[AKind];
end;

function FadeShapeId(AShape: TFadeShape): string;
begin
  Result := FADE_SHAPE_IDS[AShape];
end;

function FadeShapeFromId(const AId: string; out AShape: TFadeShape): Boolean;
var
  s: TFadeShape;
begin
  for s := Low(TFadeShape) to High(TFadeShape) do
    if SameText(AId, FADE_SHAPE_IDS[s]) then
    begin
      AShape := s;
      Exit(True);
    end;
  Result := False;
end;

function DefaultTrackHeight(AKind: TTrackKind): Integer;
begin
  case AKind of
    tkFolder: Result := 44;
    tkMaster: Result := 72;
  else
    Result := 84;
  end;
end;

function DbToGain(ADb: Double): Double;
begin
  if ADb <= -240 then Result := 0 else Result := FastExp10(ADb / 20.0);
end;

function EncodeMidiSourceId(AMidiClipId: Integer): Integer;
begin
  Result := -AMidiClipId;
end;

function DecodeMidiSourceId(ASourceId: Integer): Integer;
begin
  if ASourceId < 0 then Result := -ASourceId else Result := 0;
end;

{ ================= TMediaSource ================= }

constructor TMediaSource.Create(AId: Integer; const APath: string;
  ASampleRate, AChannels: Integer; AFrameCount: Int64; AKind: TMediaKind);
begin
  inherited Create;
  FId := AId;
  FKind := AKind;
  FPath := APath;
  FSampleRate := ASampleRate;
  FChannels := AChannels;
  FFrameCount := AFrameCount;
end;

destructor TMediaSource.Destroy;
begin
  FWaveform.Free;
  inherited Destroy;
end;

function TMediaSource.DurationSeconds: Double;
begin
  if FSampleRate > 0 then
    Result := FFrameCount / FSampleRate
  else
    Result := 0;
end;

procedure TMediaSource.EnsureWaveform(AOnProgress: TWaveformProgressEvent);
begin
  if FWaveform <> nil then Exit;
  if (FKind <> mkAudioFile) or (FPath = '') or (not FileExists(FPath)) then Exit;
  { BuildWaveformCacheFromFile sniffs the real format (MP3 / MP4-MP4a / WAV)
    rather than trusting the extension, and decodes through the matching
    codec before reducing to peaks - so MP3/MP4 clips get real waveforms
    too, not just WAV. It can still raise (e.g. AAC-in-MP4, which isn't
    decodable yet); callers of EnsureWaveform already catch that and fall
    back to the flat placeholder line, exactly as a bad WAV did before. }
  FWaveform := BuildWaveformCacheFromFile(FPath, TIMELINE_WAVE_BASE_BIN,
    TIMELINE_WAVE_FACTOR, AOnProgress);
end;

procedure TMediaSource.AttachWaveform(ACache: TWaveformCache);
begin
  if ACache = FWaveform then Exit;
  FWaveform.Free;
  FWaveform := ACache;
end;

{ ================= TTimelineClip ================= }

constructor TTimelineClip.Create(AId: Integer);
begin
  inherited Create;
  FId := AId;
  FSourceId := -1;
  FGainDb := 0;
  FColor := -1;
  FFadeInShape := fsEqualPower;
  FFadeOutShape := fsEqualPower;
end;

procedure TTimelineClip.Assign(ASrc: TTimelineClip);
begin
  FName := ASrc.FName;
  FSourceId := ASrc.FSourceId;
  FStartSeconds := ASrc.FStartSeconds;
  FSourceOffsetSeconds := ASrc.FSourceOffsetSeconds;
  FLengthSeconds := ASrc.FLengthSeconds;
  FGainDb := ASrc.FGainDb;
  FFadeInSeconds := ASrc.FFadeInSeconds;
  FFadeOutSeconds := ASrc.FFadeOutSeconds;
  FFadeInShape := ASrc.FFadeInShape;
  FFadeOutShape := ASrc.FFadeOutShape;
  FReversed := ASrc.FReversed;
  FMuted := ASrc.FMuted;
  FLocked := ASrc.FLocked;
  FLoop := ASrc.FLoop;
  FColor := ASrc.FColor;
  FEffectName := ASrc.FEffectName;
  FEffectOffsetSeconds := ASrc.FEffectOffsetSeconds;
  FEffectLengthSeconds := ASrc.FEffectLengthSeconds;
  FEffectRegions := Copy(ASrc.FEffectRegions);
  FSourceBPM := ASrc.FSourceBPM;
  FHasOrig := ASrc.FHasOrig;
  FOrigSourceId := ASrc.FOrigSourceId;
  FOrigDelta := ASrc.FOrigDelta;
end;

procedure TTimelineClip.AddEffectRegion(const AName: string; AOffset, ALength: Double;
  AColor: Integer; const AKind: string; const AParams: string);
var
  n: Integer;
begin
  n := Length(FEffectRegions);
  SetLength(FEffectRegions, n + 1);
  FEffectRegions[n].Name := AName;
  FEffectRegions[n].OffsetSeconds := AOffset;
  FEffectRegions[n].LengthSeconds := ALength;
  FEffectRegions[n].Color := AColor;
  FEffectRegions[n].Kind := AKind;
  FEffectRegions[n].Params := AParams;
end;

procedure TTimelineClip.KeepEffectsWithin(AFrom, ATo: Double);
var
  i, n: Integer;
  s, e: Double;
  kept: TArray<TClipEffectRegion>;
begin
  kept := nil;
  n := 0;
  for i := 0 to High(FEffectRegions) do
  begin
    s := FEffectRegions[i].OffsetSeconds;
    if FEffectRegions[i].LengthSeconds > 0 then
      e := s + FEffectRegions[i].LengthSeconds
    else
      e := FLengthSeconds;
    s := Max(s, AFrom);
    e := Min(e, ATo);
    if e - s < TIMELINE_MIN_CLIP_SECONDS then Continue;
    SetLength(kept, n + 1);
    kept[n] := FEffectRegions[i];
    kept[n].OffsetSeconds := s - AFrom;
    kept[n].LengthSeconds := e - s;
    Inc(n);
  end;
  FEffectRegions := kept;

  if FEffectName <> '' then
  begin
    s := FEffectOffsetSeconds;
    if FEffectLengthSeconds > 0 then
      e := s + FEffectLengthSeconds
    else
      e := FLengthSeconds;
    s := Max(s, AFrom);
    e := Min(e, ATo);
    if e - s < TIMELINE_MIN_CLIP_SECONDS then
    begin
      FEffectName := '';
      FEffectOffsetSeconds := 0;
      FEffectLengthSeconds := 0;
    end
    else
    begin
      FEffectOffsetSeconds := s - AFrom;
      FEffectLengthSeconds := e - s;
    end;
  end;
end;

function TTimelineClip.Clone: TTimelineClip;
begin
  Result := TTimelineClip.Create(FId);
  Result.Assign(Self);
end;

function TTimelineClip.HasEffects: Boolean;
begin
  Result := (Abs(FGainDb) > 0.000001) or (FFadeInSeconds > 0) or
    (FFadeOutSeconds > 0) or FReversed;
end;

function TTimelineClip.EndSeconds: Double;
begin
  Result := FStartSeconds + FLengthSeconds;
end;

function TTimelineClip.ContainsSeconds(ASeconds: Double): Boolean;
begin
  Result := (ASeconds >= FStartSeconds) and (ASeconds < EndSeconds);
end;

function TTimelineClip.IsMidiClip: Boolean;
begin
  Result := FSourceId < 0;
end;

function TTimelineClip.MidiClipId: Integer;
begin
  Result := DecodeMidiSourceId(FSourceId);
end;

procedure TTimelineClip.ClampFades;
var
  scale: Double;
begin
  if FFadeInSeconds < 0 then FFadeInSeconds := 0;
  if FFadeOutSeconds < 0 then FFadeOutSeconds := 0;
  if (FFadeInSeconds + FFadeOutSeconds > FLengthSeconds) and
     (FFadeInSeconds + FFadeOutSeconds > 0) then
  begin
    { shrink both proportionally so they meet but never cross }
    scale := FLengthSeconds / (FFadeInSeconds + FFadeOutSeconds);
    FFadeInSeconds := FFadeInSeconds * scale;
    FFadeOutSeconds := FFadeOutSeconds * scale;
  end;
end;

function ShapeRamp(AShape: TFadeShape; T: Double): Double;
begin
  if T <= 0 then Exit(0);
  if T >= 1 then Exit(1);
  case AShape of
    fsEqualPower: Result := FastSin(T * Pi / 2);
    fsLogarithmic: Result := FastPow(T, 2.0);
  else
    Result := T;   // fsLinear
  end;
end;

function TTimelineClip.GainAt(ASeconds: Double): Double;
var
  rel, g: Double;
begin
  if (ASeconds < FStartSeconds) or (ASeconds >= EndSeconds) then Exit(0);
  g := DbToGain(FGainDb);
  rel := ASeconds - FStartSeconds;
  if (FFadeInSeconds > 0) and (rel < FFadeInSeconds) then
    g := g * ShapeRamp(FFadeInShape, rel / FFadeInSeconds);
  if (FFadeOutSeconds > 0) and (rel > FLengthSeconds - FFadeOutSeconds) then
    g := g * ShapeRamp(FFadeOutShape, (FLengthSeconds - rel) / FFadeOutSeconds);
  Result := g;
end;

function TTimelineClip.ConformFactor(AStretchBPM: Double): Double;
begin
  Result := 1.0;
  if (AStretchBPM <= 0) or IsMidiClip or (FSourceBPM <= 0) then Exit;
  Result := FSourceBPM / AStretchBPM;
  if (Abs(Result - 1.0) < 0.001) or (Result < 0.25) or (Result > 4.0) then Result := 1.0;
end;

function TTimelineClip.VideoSourceSecondsAt(ASeconds, AStretchBPM: Double): Double;
begin
  Result := FSourceOffsetSeconds +
    (SourceSecondsAt(ASeconds) - FSourceOffsetSeconds) / ConformFactor(AStretchBPM);
end;

function TTimelineClip.SourceSecondsAt(ASeconds: Double): Double;
var
  rel: Double;
begin
  rel := ASeconds - FStartSeconds;
  if FReversed then
    Result := FSourceOffsetSeconds + (FLengthSeconds - rel)
  else
    Result := FSourceOffsetSeconds + rel;
end;

{ ================= TTimelineTrack ================= }

constructor TTimelineTrack.Create(AId: Integer; AKind: TTrackKind; const AName: string);
begin
  inherited Create;
  FId := AId;
  FKind := AKind;
  FName := AName;
  FColor := -1;
  FHeight := DefaultTrackHeight(AKind);
  FGainDb := 0;
  FPan := 0;
  FClips := TObjectList<TTimelineClip>.Create(True);
end;

destructor TTimelineTrack.Destroy;
begin
  FClips.Free;
  inherited Destroy;
end;

function ClipOrderBefore(const L, R: TTimelineClip): Boolean;
begin
  if L.StartSeconds <> R.StartSeconds then
    Result := L.StartSeconds < R.StartSeconds
  else
    Result := L.Id < R.Id;
end;

procedure TTimelineTrack.SortClips;
var
  i, j: Integer;
begin
  { insertion sort - clip counts per track are small and this keeps the unit
    free of comparer/anonymous-method machinery that differs across toolchains }
  for i := 1 to FClips.Count - 1 do
  begin
    j := i;
    while (j > 0) and ClipOrderBefore(FClips[j], FClips[j - 1]) do
    begin
      FClips.Exchange(j, j - 1);
      Dec(j);
    end;
  end;
end;

function TTimelineTrack.AddClip(AClip: TTimelineClip): TTimelineClip;
begin
  FClips.Add(AClip);
  SortClips;
  Result := AClip;
end;

function TTimelineTrack.ExtractClip(AClipId: Integer): TTimelineClip;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FClips.Count - 1 do
    if FClips[i].Id = AClipId then
    begin
      Result := FClips.Extract(FClips[i]);
      Exit;
    end;
end;

procedure TTimelineTrack.RemoveClip(AClipId: Integer);
var
  i: Integer;
begin
  for i := 0 to FClips.Count - 1 do
    if FClips[i].Id = AClipId then
    begin
      FClips.Delete(i);
      Exit;
    end;
end;

function TTimelineTrack.ClipById(AClipId: Integer): TTimelineClip;
var
  i: Integer;
begin
  for i := 0 to FClips.Count - 1 do
    if FClips[i].Id = AClipId then
      Exit(FClips[i]);
  Result := nil;
end;

function TTimelineTrack.IndexOfClip(AClipId: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to FClips.Count - 1 do
    if FClips[i].Id = AClipId then
      Exit(i);
  Result := -1;
end;

function TTimelineTrack.ClipAtSeconds(ASeconds: Double): TTimelineClip;
var
  i: Integer;
begin
  for i := 0 to FClips.Count - 1 do
    if FClips[i].ContainsSeconds(ASeconds) then
      Exit(FClips[i]);
  Result := nil;
end;

function TTimelineTrack.LoopFillClipAt(ASeconds, ALimit: Double): TTimelineClip;
var
  i: Integer;
  c: TTimelineClip;
begin
  Result := nil;
  if ASeconds >= ALimit then Exit;
  for i := 0 to FClips.Count - 1 do
  begin
    c := FClips[i];
    if c.Loop and not c.Muted and (c.LengthSeconds > 0.001) and (ASeconds >= c.EndSeconds) and
       ((Result = nil) or (c.EndSeconds > Result.EndSeconds)) then
      Result := c;
  end;
  { another clip further along the lane takes over from the loop }
  if Result <> nil then
    for i := 0 to FClips.Count - 1 do
      if (FClips[i] <> Result) and (FClips[i].StartSeconds > Result.EndSeconds - 0.0005) and
         (FClips[i].StartSeconds <= ASeconds) then
        Exit(nil);
end;

function TTimelineTrack.ClipCount: Integer;
begin
  Result := FClips.Count;
end;

function TTimelineTrack.GetClip(AIndex: Integer): TTimelineClip;
begin
  Result := FClips[AIndex];
end;

function TTimelineTrack.LastEndSeconds: Double;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to FClips.Count - 1 do
    if FClips[i].EndSeconds > Result then
      Result := FClips[i].EndSeconds;
end;

{ ================= TTimelineMarker / TTimelineRegion ================= }

constructor TTimelineMarker.Create(AId: Integer; const AName: string; ASeconds: Double);
begin
  inherited Create;
  FId := AId;
  FName := AName;
  FSeconds := ASeconds;
end;

constructor TTimelineChord.Create(AId: Integer; const AName: string; AStart, ALength: Double);
begin
  inherited Create;
  FId := AId;
  FName := AName;
  FStartSeconds := AStart;
  FLengthSeconds := ALength;
end;

function TTimelineChord.EndSeconds: Double;
begin
  Result := FStartSeconds + FLengthSeconds;
end;

constructor TTimelineRegion.Create(AId: Integer; const AName: string; AStart, ALength: Double);
begin
  inherited Create;
  FId := AId;
  FName := AName;
  FStartSeconds := AStart;
  FLengthSeconds := ALength;
  FColor := -1;
end;

function TTimelineRegion.EndSeconds: Double;
begin
  Result := FStartSeconds + FLengthSeconds;
end;

{ ================= TTimeline ================= }

constructor TTimeline.Create;
begin
  inherited Create;
  FTracks := TObjectList<TTimelineTrack>.Create(True);
  FSources := TObjectList<TMediaSource>.Create(True);
  FMarkers := TObjectList<TTimelineMarker>.Create(True);
  FChords := TObjectList<TTimelineChord>.Create(True);
  FNextChordId := 1;
  FRegions := TObjectList<TTimelineRegion>.Create(True);
  FVideoFx := TObjectList<TVideoEffectRegion>.Create(True);
  FNextVideoFxId := 1;
  FNextTrackId := 1;
  FNextClipId := 1;
  FNextSourceId := 1;
  FNextMarkerId := 1;
  FNextRegionId := 1;
  FHeaderWidth := TIMELINE_HEADER_WIDTH_DEFAULT;
end;

destructor TTimeline.Destroy;
begin
  FVideoFx.Free;
  FRegions.Free;
  FChords.Free;
  FMarkers.Free;
  FTracks.Free;
  FSources.Free;
  inherited Destroy;
end;

procedure TTimeline.Clear;
begin
  FTracks.Clear;
  FSources.Clear;
  FMarkers.Clear;
  FChords.Clear;
  FNextChordId := 1;
  FRegions.Clear;
  FVideoFx.Clear;
  FNextVideoFxId := 1;
  FNextTrackId := 1;
  FNextClipId := 1;
  FNextSourceId := 1;
  FNextMarkerId := 1;
  FNextRegionId := 1;
  FPlayheadSeconds := 0;
  FLoopStartSeconds := 0;
  FLoopLengthSeconds := 0;
  FLoopEnabled := False;
  FMasterVolumeDb := 0;
  FHeaderWidth := TIMELINE_HEADER_WIDTH_DEFAULT;
end;

procedure TTimeline.SetMasterVolumeDb(AValue: Double);
begin
  if IsNan(AValue) then AValue := 0;
  if AValue < -60.0 then AValue := -60.0
  else if AValue > 12.0 then AValue := 12.0;
  FMasterVolumeDb := AValue;
end;

procedure TTimeline.SetHeaderWidth(AValue: Integer);
begin
  if AValue < TIMELINE_HEADER_WIDTH_MIN then AValue := TIMELINE_HEADER_WIDTH_MIN
  else if AValue > TIMELINE_HEADER_WIDTH_MAX then AValue := TIMELINE_HEADER_WIDTH_MAX;
  FHeaderWidth := AValue;
end;

function TTimeline.Clone: TTimeline;
var
  i, j: Integer;
  srcT, dstT: TTimelineTrack;
  srcS: TMediaSource;
  c: TTimelineClip;
  m: TTimelineMarker;
  rg: TTimelineRegion;
begin
  Result := TTimeline.Create;
  for i := 0 to FSources.Count - 1 do
  begin
    srcS := FSources[i];
    Result.FSources.Add(TMediaSource.Create(srcS.Id, srcS.Path, srcS.SampleRate,
      srcS.Channels, srcS.FrameCount, srcS.Kind));
  end;
  for i := 0 to FTracks.Count - 1 do
  begin
    srcT := FTracks[i];
    dstT := TTimelineTrack.Create(srcT.Id, srcT.Kind, srcT.Name);
    dstT.Color := srcT.Color;
    dstT.Height := srcT.Height;
    dstT.Muted := srcT.Muted;
    dstT.Soloed := srcT.Soloed;
    dstT.Armed := srcT.Armed;
    dstT.GainDb := srcT.GainDb;
    dstT.Pan := srcT.Pan;
    for j := 0 to srcT.ClipCount - 1 do
    begin
      c := srcT.GetClip(j).Clone;
      dstT.FClips.Add(c);
    end;
    Result.FTracks.Add(dstT);
  end;
  for i := 0 to FMarkers.Count - 1 do
  begin
    m := FMarkers[i];
    Result.FMarkers.Add(TTimelineMarker.Create(m.Id, m.Name, m.Seconds));
    Result.FMarkers.Last.Locked := m.Locked;
  end;
  for i := 0 to FChords.Count - 1 do
  begin
    Result.FChords.Add(TTimelineChord.Create(FChords[i].Id, FChords[i].Name,
      FChords[i].StartSeconds, FChords[i].LengthSeconds));
    Result.FChords.Last.Locked := FChords[i].Locked;
  end;
  Result.FNextChordId := FNextChordId;
  for i := 0 to FRegions.Count - 1 do
  begin
    rg := FRegions[i];
    Result.FRegions.Add(TTimelineRegion.Create(rg.Id, rg.Name, rg.StartSeconds, rg.LengthSeconds));
    Result.FRegions.Last.Color := rg.Color;
    Result.FRegions.Last.Continuous := rg.Continuous;
    Result.FRegions.Last.Locked := rg.Locked;
  end;
  for i := 0 to FVideoFx.Count - 1 do
    Result.FVideoFx.Add(TVideoEffectRegion.Create(FVideoFx[i].Id, FVideoFx[i].TrackId,
      FVideoFx[i].Kind, FVideoFx[i].Name, FVideoFx[i].StartSeconds, FVideoFx[i].LengthSeconds,
      FVideoFx[i].PivotSeconds, FVideoFx[i].Params));
  Result.FNextVideoFxId := FNextVideoFxId;
  Result.FNextTrackId := FNextTrackId;
  Result.FNextClipId := FNextClipId;
  Result.FNextSourceId := FNextSourceId;
  Result.FNextMarkerId := FNextMarkerId;
  Result.FNextRegionId := FNextRegionId;
  Result.FPlayheadSeconds := FPlayheadSeconds;
  Result.FMasterVolumeDb := FMasterVolumeDb;
  Result.FLoopStartSeconds := FLoopStartSeconds;
  Result.FLoopLengthSeconds := FLoopLengthSeconds;
  Result.FLoopEnabled := FLoopEnabled;
  Result.FHeaderWidth := FHeaderWidth;
end;

procedure TTimeline.BumpTrackId(AObservedId: Integer);
begin
  if AObservedId >= FNextTrackId then FNextTrackId := AObservedId + 1;
end;

procedure TTimeline.BumpClipId(AObservedId: Integer);
begin
  if AObservedId >= FNextClipId then FNextClipId := AObservedId + 1;
end;

procedure TTimeline.BumpSourceId(AObservedId: Integer);
begin
  if AObservedId >= FNextSourceId then FNextSourceId := AObservedId + 1;
end;

procedure TTimeline.BumpMarkerId(AObservedId: Integer);
begin
  if AObservedId >= FNextMarkerId then FNextMarkerId := AObservedId + 1;
end;

procedure TTimeline.BumpRegionId(AObservedId: Integer);
begin
  if AObservedId >= FNextRegionId then FNextRegionId := AObservedId + 1;
end;

{ ---- sources ---- }

function TTimeline.AddSource(const APath: string; ASampleRate, AChannels: Integer;
  AFrameCount: Int64; AKind: TMediaKind): TMediaSource;
var
  i: Integer;
begin
  if (AKind = mkAudioFile) and (APath <> '') then
    for i := 0 to FSources.Count - 1 do
      if SameText(FSources[i].Path, APath) and (FSources[i].SampleRate = ASampleRate) and
        (FSources[i].Channels = AChannels) and (FSources[i].FrameCount = AFrameCount) then
        Exit(FSources[i]);
  Result := AddSourceWithId(FNextSourceId, APath, ASampleRate, AChannels, AFrameCount, AKind);
end;

function TTimeline.AddSourceWithId(AId: Integer; const APath: string;
  ASampleRate, AChannels: Integer; AFrameCount: Int64; AKind: TMediaKind): TMediaSource;
begin
  if SourceById(AId) <> nil then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS,
      'source id %d already in use', [AId]);
  Result := TMediaSource.Create(AId, APath, ASampleRate, AChannels, AFrameCount, AKind);
  FSources.Add(Result);
  BumpSourceId(AId);
end;

function TTimeline.SourceById(AId: Integer): TMediaSource;
var
  i: Integer;
begin
  for i := 0 to FSources.Count - 1 do
    if FSources[i].Id = AId then
      Exit(FSources[i]);
  Result := nil;
end;

function TTimeline.SourceCount: Integer;
begin
  Result := FSources.Count;
end;

function TTimeline.GetSource(AIndex: Integer): TMediaSource;
begin
  Result := FSources[AIndex];
end;

function TTimeline.SourceUseCount(ASourceId: Integer): Integer;
var
  i, j: Integer;
begin
  Result := 0;
  for i := 0 to FTracks.Count - 1 do
    for j := 0 to FTracks[i].ClipCount - 1 do
      if FTracks[i].GetClip(j).SourceId = ASourceId then
        Inc(Result);
end;

procedure TTimeline.RemoveUnusedSources;
var
  i: Integer;
begin
  for i := FSources.Count - 1 downto 0 do
    if SourceUseCount(FSources[i].Id) = 0 then
      FSources.Delete(i);
end;

{ ---- tracks ---- }

function TTimeline.AddTrack(AKind: TTrackKind; const AName: string): TTimelineTrack;
begin
  Result := AddTrackWithId(FNextTrackId, AKind, AName);
end;

function TTimeline.AddTrackWithId(AId: Integer; AKind: TTrackKind; const AName: string): TTimelineTrack;
begin
  if TrackById(AId) <> nil then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS,
      'track id %d already in use', [AId]);
  Result := TTimelineTrack.Create(AId, AKind, AName);
  FTracks.Add(Result);
  BumpTrackId(AId);
end;

procedure TTimeline.RemoveTrack(ATrackId: Integer);
var
  i: Integer;
begin
  for i := 0 to FTracks.Count - 1 do
    if FTracks[i].Id = ATrackId then
    begin
      FTracks.Delete(i);
      Exit;
    end;
  RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'no track with id %d', [ATrackId]);
end;

procedure TTimeline.MoveTrack(ATrackId, ANewIndex: Integer);
var
  cur: Integer;
begin
  cur := IndexOfTrack(ATrackId);
  if cur < 0 then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'no track with id %d', [ATrackId]);
  if ANewIndex < 0 then ANewIndex := 0;
  if ANewIndex >= FTracks.Count then ANewIndex := FTracks.Count - 1;
  if ANewIndex = cur then Exit;
  FTracks.Move(cur, ANewIndex);
end;

function TTimeline.TrackById(AId: Integer): TTimelineTrack;
var
  i: Integer;
begin
  for i := 0 to FTracks.Count - 1 do
    if FTracks[i].Id = AId then
      Exit(FTracks[i]);
  Result := nil;
end;

function TTimeline.IndexOfTrack(ATrackId: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to FTracks.Count - 1 do
    if FTracks[i].Id = ATrackId then
      Exit(i);
  Result := -1;
end;

function TTimeline.TrackCount: Integer;
begin
  Result := FTracks.Count;
end;

function TTimeline.GetTrack(AIndex: Integer): TTimelineTrack;
begin
  Result := FTracks[AIndex];
end;

{ ---- clips ---- }

function TTimeline.FindTrackOfClip(AClipId: Integer): TTimelineTrack;
var
  i: Integer;
begin
  for i := 0 to FTracks.Count - 1 do
    if FTracks[i].ClipById(AClipId) <> nil then
      Exit(FTracks[i]);
  Result := nil;
end;

procedure TTimeline.GuardUnlocked(AClip: TTimelineClip);
begin
  if AClip.Locked then
    RaiseUDAWFmt(errInvalidState, TIMELINE_MODEL_SUBSYS,
      'clip "%s" is locked', [AClip.Name]);
end;

function TTimeline.AddClip(ATrackId, ASourceId: Integer; AName: string;
  AStartSeconds, ASourceOffsetSeconds, ALengthSeconds: Double): TTimelineClip;
begin
  Result := AddClipWithId(FNextClipId, ATrackId, ASourceId, AName,
    AStartSeconds, ASourceOffsetSeconds, ALengthSeconds);
end;

function TTimeline.AddClipWithId(AClipId, ATrackId, ASourceId: Integer; AName: string;
  AStartSeconds, ASourceOffsetSeconds, ALengthSeconds: Double): TTimelineClip;
var
  trk: TTimelineTrack;
  clip: TTimelineClip;
begin
  trk := TrackById(ATrackId);
  if trk = nil then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'no track with id %d', [ATrackId]);
  if FindTrackOfClip(AClipId) <> nil then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'clip id %d already in use', [AClipId]);
  if (ASourceId >= 0) and (SourceById(ASourceId) = nil) then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'no source with id %d', [ASourceId]);
  if ALengthSeconds < TIMELINE_MIN_CLIP_SECONDS then
    RaiseUDAW(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'clip length must be positive');
  if AStartSeconds < 0 then AStartSeconds := 0;

  clip := TTimelineClip.Create(AClipId);
  clip.FName := AName;
  clip.FSourceId := ASourceId;
  clip.FStartSeconds := AStartSeconds;
  clip.FSourceOffsetSeconds := ASourceOffsetSeconds;
  clip.FLengthSeconds := ALengthSeconds;
  trk.AddClip(clip);
  BumpClipId(AClipId);
  Result := clip;
end;

procedure TTimeline.RemoveClip(AClipId: Integer);
var
  trk: TTimelineTrack;
begin
  trk := FindTrackOfClip(AClipId);
  if trk = nil then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'no clip with id %d', [AClipId]);
  trk.RemoveClip(AClipId);
end;

function TTimeline.ClipById(AClipId: Integer; out ATrack: TTimelineTrack): TTimelineClip;
begin
  ATrack := FindTrackOfClip(AClipId);
  if ATrack = nil then
    Exit(nil);
  Result := ATrack.ClipById(AClipId);
end;

function TTimeline.ClipById(AClipId: Integer): TTimelineClip;
var
  trk: TTimelineTrack;
begin
  Result := ClipById(AClipId, trk);
end;

procedure TTimeline.MoveClip(AClipId: Integer; ANewStartSeconds: Double);
begin
  MoveClip(AClipId, ANewStartSeconds, 0);
end;

procedure TTimeline.MoveClip(AClipId: Integer; ANewStartSeconds: Double; ANewTrackId: Integer);
var
  fromTrack, toTrack: TTimelineTrack;
  clip: TTimelineClip;
begin
  clip := ClipById(AClipId, fromTrack);
  if clip = nil then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'no clip with id %d', [AClipId]);
  GuardUnlocked(clip);
  if ANewStartSeconds < 0 then ANewStartSeconds := 0;

  if (ANewTrackId > 0) and (ANewTrackId <> fromTrack.Id) then
  begin
    toTrack := TrackById(ANewTrackId);
    if toTrack = nil then
      RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'no track with id %d', [ANewTrackId]);
    clip := fromTrack.ExtractClip(AClipId);
    clip.FStartSeconds := ANewStartSeconds;
    toTrack.AddClip(clip);
  end
  else
  begin
    clip.FStartSeconds := ANewStartSeconds;
    fromTrack.SortClips;
  end;
end;

function TTimeline.SplitClip(AClipId: Integer; ASeconds: Double; ANewClipId: Integer): TTimelineClip;
var
  trk: TTimelineTrack;
  clip, right: TTimelineClip;
  leftLen, rightLen: Double;
  newId: Integer;
begin
  clip := ClipById(AClipId, trk);
  if clip = nil then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'no clip with id %d', [AClipId]);
  GuardUnlocked(clip);
  if (ASeconds <= clip.StartSeconds + TIMELINE_MIN_CLIP_SECONDS) or
     (ASeconds >= clip.EndSeconds - TIMELINE_MIN_CLIP_SECONDS) then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS,
      'split point %.6f is outside the body of clip "%s"', [ASeconds, clip.Name]);

  leftLen := ASeconds - clip.StartSeconds;
  rightLen := clip.EndSeconds - ASeconds;

  if ANewClipId > 0 then newId := ANewClipId else newId := FNextClipId;
  if FindTrackOfClip(newId) <> nil then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'clip id %d already in use', [newId]);

  right := TTimelineClip.Create(newId);
  right.Assign(clip);
  { each half keeps only the effect regions that lie inside it - rebased to
    its own start - while both still hold the pre-split length }
  right.KeepEffectsWithin(leftLen, leftLen + rightLen);
  clip.KeepEffectsWithin(0, leftLen);
  right.FStartSeconds := ASeconds;
  right.FLengthSeconds := rightLen;
  { non-destructive: the right window continues from where the split lands }
  if clip.Reversed then
    right.FSourceOffsetSeconds := clip.SourceOffsetSeconds
  else
    right.FSourceOffsetSeconds := clip.SourceOffsetSeconds + leftLen;
  right.FFadeInSeconds := 0;                       // only the outer edges keep their fades
  right.FFadeOutSeconds := clip.FadeOutSeconds;

  clip.FLengthSeconds := leftLen;
  clip.FFadeOutSeconds := 0;
  if clip.Reversed then
    clip.FSourceOffsetSeconds := clip.SourceOffsetSeconds + rightLen;
  clip.ClampFades;
  right.ClampFades;

  trk.AddClip(right);
  BumpClipId(newId);
  Result := right;
end;

procedure TTimeline.TrimClip(AClipId: Integer; AEdge: TClipEdge; ANewSeconds: Double);
var
  clip: TTimelineClip;
  trk: TTimelineTrack;
  delta, newLen: Double;
begin
  clip := ClipById(AClipId, trk);
  if clip = nil then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'no clip with id %d', [AClipId]);
  GuardUnlocked(clip);

  if AEdge = ceStart then
  begin
    if ANewSeconds < 0 then ANewSeconds := 0;
    if ANewSeconds >= clip.EndSeconds - TIMELINE_MIN_CLIP_SECONDS then
      RaiseUDAW(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'trim would collapse the clip');
    delta := ANewSeconds - clip.StartSeconds;   // >0 shrinks from the left
    { effect regions are measured from the clip's start, so they move with
      it: rebased onto the new start, and whatever the new head cuts off is
      dropped (a pull outwards, delta < 0, just shifts them right) }
    clip.KeepEffectsWithin(delta, clip.FLengthSeconds);
    clip.FStartSeconds := ANewSeconds;
    clip.FLengthSeconds := clip.FLengthSeconds - delta;
    if not clip.Reversed then
      clip.FSourceOffsetSeconds := clip.FSourceOffsetSeconds + delta;
    trk.SortClips;
  end
  else
  begin
    newLen := ANewSeconds - clip.StartSeconds;
    if newLen < TIMELINE_MIN_CLIP_SECONDS then
      RaiseUDAW(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'trim would collapse the clip');
    if clip.Reversed then
      clip.FSourceOffsetSeconds := clip.FSourceOffsetSeconds + (newLen - clip.FLengthSeconds);
    clip.FLengthSeconds := newLen;
  end;
  clip.ClampFades;
end;

procedure TTimeline.SlipClip(AClipId: Integer; ADeltaSeconds: Double);
var
  clip: TTimelineClip;
begin
  clip := ClipById(AClipId);
  if clip = nil then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'no clip with id %d', [AClipId]);
  GuardUnlocked(clip);
  clip.FSourceOffsetSeconds := clip.FSourceOffsetSeconds + ADeltaSeconds;
end;

function TTimeline.DuplicateClip(AClipId: Integer; ANewClipId: Integer): TTimelineClip;
var
  clip, dup: TTimelineClip;
  trk: TTimelineTrack;
  newId: Integer;
begin
  clip := ClipById(AClipId, trk);
  if clip = nil then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'no clip with id %d', [AClipId]);
  if ANewClipId > 0 then newId := ANewClipId else newId := FNextClipId;
  if FindTrackOfClip(newId) <> nil then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'clip id %d already in use', [newId]);

  dup := TTimelineClip.Create(newId);
  dup.Assign(clip);
  dup.FStartSeconds := clip.EndSeconds;
  dup.FLocked := False;
  trk.AddClip(dup);
  BumpClipId(newId);
  Result := dup;
end;

procedure TTimeline.SetClipGain(AClipId: Integer; AGainDb: Double);
var
  clip: TTimelineClip;
begin
  clip := ClipById(AClipId);
  if clip = nil then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'no clip with id %d', [AClipId]);
  GuardUnlocked(clip);
  clip.FGainDb := AGainDb;
end;

procedure TTimeline.SetClipSource(AClipId: Integer; ANewSourceId: Integer;
  ANewSourceOffsetSeconds: Double);
var
  clip: TTimelineClip;
begin
  clip := ClipById(AClipId);
  if clip = nil then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'no clip with id %d', [AClipId]);
  GuardUnlocked(clip);
  clip.FSourceId := ANewSourceId;
  clip.FSourceOffsetSeconds := ANewSourceOffsetSeconds;
end;

procedure TTimeline.SetClipFades(AClipId: Integer; AFadeInSeconds, AFadeOutSeconds: Double);
var
  clip: TTimelineClip;
begin
  clip := ClipById(AClipId);
  if clip = nil then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'no clip with id %d', [AClipId]);
  GuardUnlocked(clip);
  clip.FFadeInSeconds := Max(0, AFadeInSeconds);
  clip.FFadeOutSeconds := Max(0, AFadeOutSeconds);
  clip.ClampFades;
end;

procedure TTimeline.SetClipReversed(AClipId: Integer; AReversed: Boolean);
var
  clip: TTimelineClip;
begin
  clip := ClipById(AClipId);
  if clip = nil then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'no clip with id %d', [AClipId]);
  GuardUnlocked(clip);
  clip.FReversed := AReversed;
end;

procedure TTimeline.SetClipMuted(AClipId: Integer; AMuted: Boolean);
var
  clip: TTimelineClip;
begin
  clip := ClipById(AClipId);
  if clip = nil then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'no clip with id %d', [AClipId]);
  clip.FMuted := AMuted;
end;

procedure TTimeline.SetClipLocked(AClipId: Integer; ALocked: Boolean);
var
  clip: TTimelineClip;
begin
  clip := ClipById(AClipId);
  if clip = nil then
    RaiseUDAWFmt(errInvalidArgument, TIMELINE_MODEL_SUBSYS, 'no clip with id %d', [AClipId]);
  clip.FLocked := ALocked;
end;

{ ---- chords ---- }

function TTimeline.AddChord(const AName: string; AStart, ALength: Double): TTimelineChord;
begin
  Result := AddChordWithId(FNextChordId, AName, AStart, ALength);
end;

function TTimeline.AddChordWithId(AId: Integer; const AName: string; AStart, ALength: Double): TTimelineChord;
var
  i: Integer;
begin
  Result := TTimelineChord.Create(AId, AName, Max(0, AStart), Max(0.01, ALength));
  { kept sorted by start so the lane paints and searches in order }
  i := FChords.Count;
  while (i > 0) and (FChords[i - 1].StartSeconds > Result.StartSeconds) do Dec(i);
  FChords.Insert(i, Result);
  if AId >= FNextChordId then FNextChordId := AId + 1;
end;

procedure TTimeline.RemoveChord(AId: Integer);
var
  i: Integer;
begin
  for i := 0 to FChords.Count - 1 do
    if FChords[i].Id = AId then
    begin
      FChords.Delete(i);
      Exit;
    end;
end;

function TTimeline.ChordCount: Integer;
begin
  Result := FChords.Count;
end;

function TTimeline.GetChord(AIndex: Integer): TTimelineChord;
begin
  Result := FChords[AIndex];
end;

function TTimeline.ChordById(AId: Integer): TTimelineChord;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FChords.Count - 1 do
    if FChords[i].Id = AId then Exit(FChords[i]);
end;

function TTimeline.ChordAt(ASeconds: Double): TTimelineChord;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FChords.Count - 1 do
    if (ASeconds >= FChords[i].StartSeconds) and (ASeconds < FChords[i].EndSeconds) then
      Exit(FChords[i]);
end;

{ "id,start,length,name" entries joined by ';' - the symbols never contain either
  separator (they are stripped on entry) }
function TTimeline.ChordsSnapshot: string;
var
  i: Integer;
  sb: TStringBuilder;
  fs: TFormatSettings;
begin
  fs := TFormatSettings.Invariant;
  sb := TStringBuilder.Create;
  try
    for i := 0 to FChords.Count - 1 do
      sb.Append(FChords[i].Id).Append(',').Append(FormatFloat('0.######', FChords[i].StartSeconds, fs))
        .Append(',').Append(FormatFloat('0.######', FChords[i].LengthSeconds, fs)).Append(',')
        .Append(StringReplace(StringReplace(FChords[i].Name, ',', ' ', [rfReplaceAll]), ';', ' ', [rfReplaceAll]))
        .Append(';');
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

procedure TTimeline.RestoreChords(const ASnapshot: string);
var
  entries, f: TArray<string>;
  e: string;
  fs: TFormatSettings;
  id: Integer;
  st, ln: Double;
begin
  fs := TFormatSettings.Invariant;
  FChords.Clear;
  entries := ASnapshot.Split([';']);
  for e in entries do
  begin
    if e = '' then Continue;
    f := e.Split([','], 4);
    if Length(f) < 4 then Continue;
    if not TryStrToInt(f[0], id) then Continue;
    if not TryStrToFloat(f[1], st, fs) then Continue;
    if not TryStrToFloat(f[2], ln, fs) then Continue;
    AddChordWithId(id, f[3], st, ln);
  end;
end;

{ ---- markers / regions ---- }

function TTimeline.AddMarker(const AName: string; ASeconds: Double): TTimelineMarker;
begin
  Result := AddMarkerWithId(FNextMarkerId, AName, ASeconds);
end;

function TTimeline.AddMarkerWithId(AId: Integer; const AName: string; ASeconds: Double): TTimelineMarker;
begin
  Result := TTimelineMarker.Create(AId, AName, Max(0, ASeconds));
  FMarkers.Add(Result);
  BumpMarkerId(AId);
end;

procedure TTimeline.RemoveMarker(AId: Integer);
var
  i: Integer;
begin
  for i := 0 to FMarkers.Count - 1 do
    if FMarkers[i].Id = AId then
    begin
      FMarkers.Delete(i);
      Exit;
    end;
end;

function TTimeline.MarkerCount: Integer;
begin
  Result := FMarkers.Count;
end;

function TTimeline.GetMarker(AIndex: Integer): TTimelineMarker;
begin
  Result := FMarkers[AIndex];
end;

function TTimeline.AddRegion(const AName: string; AStart, ALength: Double): TTimelineRegion;
begin
  Result := AddRegionWithId(FNextRegionId, AName, AStart, ALength);
end;

function TTimeline.AddRegionWithId(AId: Integer; const AName: string; AStart, ALength: Double): TTimelineRegion;
begin
  if ALength < 0 then ALength := 0;
  Result := TTimelineRegion.Create(AId, AName, Max(0, AStart), ALength);
  FRegions.Add(Result);
  BumpRegionId(AId);
end;

procedure TTimeline.RemoveRegion(AId: Integer);
var
  i: Integer;
begin
  for i := 0 to FRegions.Count - 1 do
    if FRegions[i].Id = AId then
    begin
      FRegions.Delete(i);
      Exit;
    end;
end;

{ ---- video effects ---- }

constructor TVideoEffectRegion.Create(AId, ATrackId: Integer; const AKind, AName: string;
  AStart, ALength, APivot: Double; const AParams: string);
begin
  inherited Create;
  FId := AId;
  FTrackId := ATrackId;
  FKind := AKind;
  FName := AName;
  FStartSeconds := AStart;
  FLengthSeconds := ALength;
  FPivotSeconds := APivot;
  FParams := AParams;
end;

function TVideoEffectRegion.EndSeconds: Double;
begin
  Result := FStartSeconds + FLengthSeconds;
end;

function TTimeline.AddVideoEffect(ATrackId: Integer; const AKind, AName: string;
  AStart, ALength, APivot: Double; const AParams: string): TVideoEffectRegion;
begin
  Result := AddVideoEffectWithId(FNextVideoFxId, ATrackId, AKind, AName, AStart, ALength,
    APivot, AParams);
end;

function TTimeline.AddVideoEffectWithId(AId, ATrackId: Integer; const AKind, AName: string;
  AStart, ALength, APivot: Double; const AParams: string): TVideoEffectRegion;
begin
  if ALength < 0 then ALength := 0;
  Result := TVideoEffectRegion.Create(AId, ATrackId, AKind, AName, Max(0, AStart), ALength,
    APivot, AParams);
  FVideoFx.Add(Result);
  BumpVideoEffectId(AId);
end;

procedure TTimeline.RemoveVideoEffect(AId: Integer);
var
  i: Integer;
begin
  for i := 0 to FVideoFx.Count - 1 do
    if FVideoFx[i].Id = AId then
    begin
      FVideoFx.Delete(i);
      Exit;
    end;
end;

function TTimeline.VideoEffectCount: Integer;
begin
  Result := FVideoFx.Count;
end;

function TTimeline.GetVideoEffect(AIndex: Integer): TVideoEffectRegion;
begin
  Result := FVideoFx[AIndex];
end;

function TTimeline.VideoEffectById(AId: Integer): TVideoEffectRegion;
var
  i: Integer;
begin
  for i := 0 to FVideoFx.Count - 1 do
    if FVideoFx[i].Id = AId then Exit(FVideoFx[i]);
  Result := nil;
end;

procedure TTimeline.BumpVideoEffectId(AObservedId: Integer);
begin
  if AObservedId >= FNextVideoFxId then FNextVideoFxId := AObservedId + 1;
end;

function TTimeline.RegionCount: Integer;
begin
  Result := FRegions.Count;
end;

function TTimeline.GetRegion(AIndex: Integer): TTimelineRegion;
begin
  Result := FRegions[AIndex];
end;

{ ---- queries ---- }

function TTimeline.TotalDurationSeconds: Double;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to FTracks.Count - 1 do
    if FTracks[i].LastEndSeconds > Result then
      Result := FTracks[i].LastEndSeconds;
  for i := 0 to FMarkers.Count - 1 do
    if FMarkers[i].Seconds > Result then
      Result := FMarkers[i].Seconds;
  for i := 0 to FRegions.Count - 1 do
    if FRegions[i].EndSeconds > Result then
      Result := FRegions[i].EndSeconds;
  if FLoopEnabled and (FLoopStartSeconds + FLoopLengthSeconds > Result) then
    Result := FLoopStartSeconds + FLoopLengthSeconds;
end;

{ Content-only end point: the latest clip end across every track, ignoring
  markers/regions/loop bounds. TotalDurationSeconds folds those in too - fine
  for the ruler/export, which should stretch to cover a marker or region the
  user placed past the last clip - but the transport must stop at the last
  actual note, not run on through silence to some marker/region/loop bound
  left over from before the clips near the end were cut/trimmed/deleted. }
function TTimeline.LastClipEndSeconds: Double;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to FTracks.Count - 1 do
    if FTracks[i].LastEndSeconds > Result then
      Result := FTracks[i].LastEndSeconds;
end;

function TTimeline.ClipCountTotal: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to FTracks.Count - 1 do
    Inc(Result, FTracks[i].ClipCount);
end;

function TTimeline.Describe: string;
var
  i, j: Integer;
  trk: TTimelineTrack;
  c: TTimelineClip;
  sb: TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    sb.AppendLine(Format('timeline: %d tracks, %d clips, %d sources, %d markers, %d regions',
      [FTracks.Count, ClipCountTotal, FSources.Count, FMarkers.Count, FRegions.Count]));
    sb.AppendLine(Format('  playhead %s   total %.3f s',
      [FormatTimecode(FPlayheadSeconds), TotalDurationSeconds]));
    for i := 0 to FTracks.Count - 1 do
    begin
      trk := FTracks[i];
      sb.AppendLine(Format('  [%d] %-10s "%s"  %d clip(s)  gain %.1f dB%s%s',
        [trk.Id, TrackKindDisplay(trk.Kind), trk.Name, trk.ClipCount, trk.GainDb,
         IfThen(trk.Muted, '  MUTE', ''), IfThen(trk.Soloed, '  SOLO', '')]));
      for j := 0 to trk.ClipCount - 1 do
      begin
        c := trk.GetClip(j);
        sb.AppendLine(Format('      clip %d "%s"  start %.3f  len %.3f  off %.3f  gain %.1f%s%s%s',
          [c.Id, c.Name, c.StartSeconds, c.LengthSeconds, c.SourceOffsetSeconds, c.GainDb,
           IfThen(c.Reversed, '  REV', ''), IfThen(c.Muted, '  MUTE', ''),
           IfThen(c.Locked, '  LOCK', '')]));
      end;
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

end.
