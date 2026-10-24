unit UDAW.Project.Document;
{$I udaw.inc}

{ Phase 5 - Project System: the in-memory project document.

  TProjectDocument is the root object a UDAW project revolves around: identity
  (a stable UUID that survives renames/moves), versioning, transport/tempo
  metadata, and the master audio routing graph built in Phase 4. Later phases
  (Timeline, Mixer, Tracker, MIDI, AI history, ...) add their own sections to
  the same document/serializer pair without touching what already exists here.

  The document owns no file handle and does no IO itself - see
  UDAW.Project.Serialization for save/open and UDAW.Project.Recovery for
  autosave/crash recovery. Every mutating property setter marks the document
  dirty and stamps ModifiedUTC, so autosave and the "unsaved changes" UI never
  need a parallel bookkeeping pass. }

interface

uses
  SysUtils, Math,
  UDAW.Errors,
  UDAW.Audio.Graph, UDAW.Audio.Graph.Nodes,
  UDAW.Timeline.Time, UDAW.Timeline.Model,
  UDAW.Mixer.Model,
  UDAW.Tracker.Pattern,
  UDAW.MIDI.Serialization, UDAW.Pattern.Model, UDAW.Drum.KitModel,
  UDAW.Composer.SongSpec, UDAW.Composer.Lyrics,
  UDAW.Project.WindowLayout, UDAW.Project.DialogPaths;

const
  PROJECT_SUBSYS = 'Project';

  PROJECT_DEFAULT_TEMPO      = 120.0;
  PROJECT_MIN_TEMPO          = 20.0;
  PROJECT_MAX_TEMPO          = 999.0;
  PROJECT_DEFAULT_TSIG_NUM   = 4;
  PROJECT_DEFAULT_TSIG_DEN   = 4;
  PROJECT_DEFAULT_NAME       = 'Untitled Project';

  EXPORT_MIN_VIDEO_KBPS = 500;
  EXPORT_MAX_VIDEO_KBPS = 80000;
  EXPORT_MIN_AUDIO_KBPS = 64;
  EXPORT_MAX_AUDIO_KBPS = 320;
  EXPORT_MIN_WIDTH      = 320;
  SCORE_SPREAD_MIN      = 0.5;    // Score vertical spacing: tightest ...
  SCORE_SPREAD_MAX      = 3.0;    // ... and widest
  EXPORT_MAX_WIDTH      = 7680;

type
  { Per-project export options (Settings > Export). Saved in the project file
    and restored when it is loaded. Zero means "automatic": a bitrate derived
    from the picture size / the original picture width. }
  TExportSettings = record
    VideoBitrateKbps: Integer;   // 0 = automatic
    MaxWidth: Integer;           // 0 = keep the source picture size
    AudioBitrateKbps: Integer;   // 0 = automatic (MP3 / MP4 / M4A / MKV sound)
    procedure Normalize;
  end;

  TProjectDocument = class
  private
    FExport: TExportSettings;
    FScoreSpread: Double;       // vertical spacing of the Score (1.0 = normal)
    FUUID: TGUID;
    FName: string;
    FAuthor: string;
    FTempoBPM: Double;
    FTempoMap: TTempoPoints;      // tempo changes after time 0 (see UDAW.Timeline.Time)
    FTimeSigNum: Integer;
    FTimeSigDen: Integer;
    FSampleRate: Integer;
    FChannels: Integer;
    FCreatedUTC: TDateTime;
    FModifiedUTC: TDateTime;
    FFileName: string;
    FDirty: Boolean;
    FGraph: TAudioGraph;
    FTimeline: TTimeline;
    FMixer: TMixerModel;
    FTrackerMixer: TMixerModel;
    FTracker: TTrackerModule;
    FMidi: TMidiProject;
    FPatterns: TPatternLibrary;
    FDrumKit: TDrumKitModel;
    FSongSpec: TSongSpec;
    FLyrics: TLyricDocument;
    FWindows: TWindowLayout;
    FDialogPaths: TDialogPaths;
    procedure SetName(const AValue: string);
    procedure SetAuthor(const AValue: string);
    procedure SetExport(const AValue: TExportSettings);
    procedure SetScoreSpread(AValue: Double);
    procedure SetTempoBPM(AValue: Double);
    procedure SetTempoMap(const AValue: TTempoPoints);
    procedure SetTimeSigNum(AValue: Integer);
    procedure SetTimeSigDen(AValue: Integer);
    procedure SetSampleRate(AValue: Integer);
    procedure SetChannels(AValue: Integer);
    procedure MarkDirty;
  public
    { A brand-new project: fresh UUID, sane defaults, a graph containing only
      the persistent Master output node (every future track/bus connects into
      it - there is nothing to accidentally route audio through yet). }
    constructor CreateNew(const AName: string = PROJECT_DEFAULT_NAME);
    { An empty shell for the deserializer to populate; UUID is generated here
      too so a malformed document can never leave a zero UUID. }
    constructor Create;
    destructor Destroy; override;

    { For the recovery manager: a deep, independent copy (own Graph object)
      that can be serialized on a background job without racing edits made
      to the live document on the UI thread. }
    function Clone: TProjectDocument;

    procedure Touch;
    procedure ClearDirty;
    { Adopts a freshly-parsed graph, freeing whatever graph the document
      currently owns. Used only by the deserializer - normal code mutates
      Graph in place through its own edit API. }
    procedure ReplaceGraph(AGraph: TAudioGraph);
    { Adopts a freshly-parsed timeline, freeing the current one. Used only by
      the deserializer - normal code mutates Timeline in place / via commands. }
    procedure ReplaceTimeline(ATimeline: TTimeline);
    { Adopts a freshly-parsed mixer, freeing the current one. Used only by the
      deserializer - normal code mutates Mixer in place / via commands. }
    procedure ReplaceMixer(AMixer: TMixerModel);
    { Adopts a freshly-parsed Tracker mixer (the TRK-CHN strips + master the Tracker plays through),
      freeing the current one. }
    procedure ReplaceTrackerMixer(AMixer: TMixerModel);
    { Adopts a freshly-parsed tracker module, freeing the current one. Used
      only by the deserializer - normal code edits Tracker via commands. }
    procedure ReplaceTracker(ATracker: TTrackerModule);
    { Adopts a freshly-parsed MIDI project, freeing the current one. Used only
      by the deserializer - normal code edits Midi via commands. }
    procedure ReplaceMidi(AMidi: TMidiProject);
    { Adopts a freshly-parsed pattern library, freeing the current one. Used by the
      deserializer and by pattern undo / redo (UDAW.Pattern.Commands). }
    procedure ReplacePatterns(APatterns: TPatternLibrary);
    { Adopts a freshly-parsed drum kit, freeing the current one. }
    procedure ReplaceDrumKit(AKit: TDrumKitModel);
    { Adopts a freshly-parsed/generated Song Specification, freeing the
      current one. Normal code edits SongSpec via UDAW.Composer.Commands. }
    procedure ReplaceSongSpec(ASpec: TSongSpec);
    { Adopts a freshly-parsed/generated lyric document, freeing the current
      one. Normal code edits Lyrics via UDAW.Composer.Commands. }
    procedure ReplaceLyrics(ALyrics: TLyricDocument);
    { Adopts a freshly-parsed remembered-window layout, freeing the current
      one. Used only by the deserializer - normal code mutates Windows in
      place (Put/Remove) as windows open, move, resize, and close; window
      geometry is not undo-tracked. }
    procedure ReplaceWindows(AWindows: TWindowLayout);
    procedure ReplaceDialogPaths(APaths: TDialogPaths);
    { The tempo / time-signature / sample-rate context timeline math needs. }
    function GridContext: TGridContext;

    property UUID: TGUID read FUUID write FUUID;
    property Name: string read FName write SetName;
    { Author / artist name stamped into MP3/MP4/M4A exports. May be empty. }
    property Author: string read FAuthor write SetAuthor;
    { Export quality / size, saved with the project. }
    property ExportSettings: TExportSettings read FExport write SetExport;
    { How far apart the Score spreads its lines vertically - the gap between the two staves of a
      grand staff and the space between lines of music; 1.0 is normal. Saved with the project and
      used for the PDF as well as on screen. }
    property ScoreSpread: Double read FScoreSpread write SetScoreSpread;
    property TempoBPM: Double read FTempoBPM write SetTempoBPM;
    { tempo changes after time 0 (sorted, de-duplicated, clamped to the tempo range);
      TempoBPM is the tempo before the first point }
    property TempoMap: TTempoPoints read FTempoMap write SetTempoMap;
    property TimeSigNum: Integer read FTimeSigNum write SetTimeSigNum;
    property TimeSigDen: Integer read FTimeSigDen write SetTimeSigDen;
    property SampleRate: Integer read FSampleRate write SetSampleRate;
    property Channels: Integer read FChannels write SetChannels;
    property CreatedUTC: TDateTime read FCreatedUTC write FCreatedUTC;
    property ModifiedUTC: TDateTime read FModifiedUTC write FModifiedUTC;
    property FileName: string read FFileName write FFileName;
    property Dirty: Boolean read FDirty;
    property Graph: TAudioGraph read FGraph;
    property Timeline: TTimeline read FTimeline;
    property Mixer: TMixerModel read FMixer;
    { the mixer the Tracker plays through: one TRK-CHN<n> strip per tracker channel and a master }
    property TrackerMixer: TMixerModel read FTrackerMixer;
    property Tracker: TTrackerModule read FTracker;
    property Midi: TMidiProject read FMidi;
    property Patterns: TPatternLibrary read FPatterns;
    { the drum machine's pads (sample, level, pan ... and a waveform overview) as saved with the project }
    property DrumKit: TDrumKitModel read FDrumKit;
    property SongSpec: TSongSpec read FSongSpec;
    property Lyrics: TLyricDocument read FLyrics;
    property Windows: TWindowLayout read FWindows;
    { the last path each file dialog was used with, saved in the project }
    property DialogPaths: TDialogPaths read FDialogPaths;

    function Describe: string;
  end;

implementation

uses
  UDAW.Tracker.Player;

procedure TExportSettings.Normalize;
begin
  if VideoBitrateKbps <= 0 then VideoBitrateKbps := 0
  else VideoBitrateKbps := EnsureRange(VideoBitrateKbps, EXPORT_MIN_VIDEO_KBPS, EXPORT_MAX_VIDEO_KBPS);
  if AudioBitrateKbps <= 0 then AudioBitrateKbps := 0
  else AudioBitrateKbps := EnsureRange(AudioBitrateKbps, EXPORT_MIN_AUDIO_KBPS, EXPORT_MAX_AUDIO_KBPS);
  if MaxWidth <= 0 then MaxWidth := 0
  else MaxWidth := EnsureRange(MaxWidth, EXPORT_MIN_WIDTH, EXPORT_MAX_WIDTH);
end;

procedure TProjectDocument.SetScoreSpread(AValue: Double);
begin
  AValue := EnsureRange(AValue, SCORE_SPREAD_MIN, SCORE_SPREAD_MAX);
  if SameValue(AValue, FScoreSpread, 1.0E-6) then Exit;
  FScoreSpread := AValue;
  MarkDirty;
end;

procedure TProjectDocument.SetExport(const AValue: TExportSettings);
var
  v: TExportSettings;
begin
  v := AValue;
  v.Normalize;
  if (v.VideoBitrateKbps = FExport.VideoBitrateKbps) and (v.MaxWidth = FExport.MaxWidth) and
     (v.AudioBitrateKbps = FExport.AudioBitrateKbps) then Exit;
  FExport := v;
  MarkDirty;
end;

constructor TProjectDocument.Create;
begin
  inherited Create;
  CreateGUID(FUUID);
  FName := PROJECT_DEFAULT_NAME;
  FScoreSpread := 1.0;
  FTempoBPM := PROJECT_DEFAULT_TEMPO;
  FTimeSigNum := PROJECT_DEFAULT_TSIG_NUM;
  FTimeSigDen := PROJECT_DEFAULT_TSIG_DEN;
  FSampleRate := 48000;
  FChannels := 2;
  FCreatedUTC := Now;
  FModifiedUTC := FCreatedUTC;
  FGraph := TAudioGraph.Create(FChannels);
  FTimeline := TTimeline.Create;
  FMixer := TMixerModel.Create;
  FTrackerMixer := TMixerModel.Create;
  FTracker := TTrackerModule.Create;
  FMidi := TMidiProject.Create;
  FPatterns := TPatternLibrary.Create;
  FDrumKit := TDrumKitModel.Create;
  FSongSpec := TSongSpec.Create;
  FLyrics := TLyricDocument.Create;
  FWindows := TWindowLayout.Create;
  FDialogPaths := TDialogPaths.Create;
end;

constructor TProjectDocument.CreateNew(const AName: string);
begin
  Create;
  if Trim(AName) <> '' then
    FName := Trim(AName);
  FGraph.AddNode(nkOutput, 'Master');
  FMixer.InitDefault;
  FTrackerMixer.InitDefault;
  FTracker.InitDefault;
  EnsureTrackerMixerStrips(FTrackerMixer, FTracker.Channels, FTracker);
end;

destructor TProjectDocument.Destroy;
begin
  FWindows.Free;
  FDialogPaths.Free;
  FLyrics.Free;
  FSongSpec.Free;
  FDrumKit.Free;
  FPatterns.Free;
  FMidi.Free;
  FTracker.Free;
  FTrackerMixer.Free;
  FMixer.Free;
  FTimeline.Free;
  FGraph.Free;
  inherited Destroy;
end;

function TProjectDocument.Clone: TProjectDocument;
var
  i: Integer;
  src, dst: TAudioNode;
  c: TGraphConn;
begin
  Result := TProjectDocument.Create;
  Result.FGraph.Free;
  Result.FGraph := TAudioGraph.Create(FChannels);
  Result.FUUID := FUUID;
  Result.FName := FName;
  Result.FAuthor := FAuthor;
  Result.FExport := FExport;
  Result.FScoreSpread := FScoreSpread;
  Result.FTempoBPM := FTempoBPM;
  Result.FTempoMap := Copy(FTempoMap);
  Result.FTimeSigNum := FTimeSigNum;
  Result.FTimeSigDen := FTimeSigDen;
  Result.FSampleRate := FSampleRate;
  Result.FChannels := FChannels;
  Result.FCreatedUTC := FCreatedUTC;
  Result.FModifiedUTC := FModifiedUTC;
  Result.FFileName := FFileName;
  Result.FDirty := FDirty;

  for i := 0 to FGraph.NodeCount - 1 do
  begin
    src := FGraph.GetNode(i);
    dst := Result.FGraph.AddNodeWithId(src.Id, src.Kind, src.Name);
    dst.DeserializeParams(src.SerializeParams);
    dst.Bypass := src.Bypass;
    dst.Mute := src.Mute;
  end;
  for i := 0 to FGraph.ConnectionCount - 1 do
  begin
    c := FGraph.GetConnection(i);
    Result.FGraph.Connect(c.FromId, c.ToId);
  end;

  Result.FTimeline.Free;
  Result.FTimeline := FTimeline.Clone;

  Result.FMixer.Free;
  Result.FMixer := FMixer.Clone;

  Result.FTrackerMixer.Free;
  Result.FTrackerMixer := FTrackerMixer.Clone;

  Result.FTracker.Free;
  Result.FTracker := FTracker.Clone;

  Result.FMidi.Free;
  Result.FMidi := FMidi.Clone;

  Result.FPatterns.Free;
  Result.FPatterns := FPatterns.Clone;

  Result.FDrumKit.Free;
  Result.FDrumKit := FDrumKit.Clone;

  Result.FSongSpec.Free;
  Result.FSongSpec := FSongSpec.Clone;

  Result.FLyrics.Free;
  Result.FLyrics := FLyrics.Clone;

  Result.FWindows.Free;
  Result.FWindows := FWindows.Clone;
  Result.FDialogPaths.Free;
  Result.FDialogPaths := FDialogPaths.Clone;
end;

procedure TProjectDocument.ReplaceGraph(AGraph: TAudioGraph);
begin
  if AGraph = FGraph then Exit;
  FGraph.Free;
  FGraph := AGraph;
end;

procedure TProjectDocument.ReplaceTimeline(ATimeline: TTimeline);
begin
  if ATimeline = FTimeline then Exit;
  FTimeline.Free;
  FTimeline := ATimeline;
end;

procedure TProjectDocument.ReplaceMixer(AMixer: TMixerModel);
begin
  if AMixer = FMixer then Exit;
  FMixer.Free;
  FMixer := AMixer;
end;

procedure TProjectDocument.ReplaceTrackerMixer(AMixer: TMixerModel);
begin
  if AMixer = FTrackerMixer then Exit;
  FTrackerMixer.Free;
  FTrackerMixer := AMixer;
end;

procedure TProjectDocument.ReplaceTracker(ATracker: TTrackerModule);
begin
  if ATracker = FTracker then Exit;
  FTracker.Free;
  FTracker := ATracker;
end;

procedure TProjectDocument.ReplaceMidi(AMidi: TMidiProject);
begin
  if AMidi = FMidi then Exit;
  FMidi.Free;
  FMidi := AMidi;
end;

procedure TProjectDocument.ReplacePatterns(APatterns: TPatternLibrary);
begin
  if APatterns = FPatterns then Exit;
  FPatterns.Free;
  FPatterns := APatterns;
end;

procedure TProjectDocument.ReplaceDrumKit(AKit: TDrumKitModel);
begin
  if AKit = FDrumKit then Exit;
  FDrumKit.Free;
  FDrumKit := AKit;
end;

procedure TProjectDocument.ReplaceSongSpec(ASpec: TSongSpec);
begin
  if ASpec = FSongSpec then Exit;
  FSongSpec.Free;
  FSongSpec := ASpec;
end;

procedure TProjectDocument.ReplaceLyrics(ALyrics: TLyricDocument);
begin
  if ALyrics = FLyrics then Exit;
  FLyrics.Free;
  FLyrics := ALyrics;
end;

procedure TProjectDocument.ReplaceWindows(AWindows: TWindowLayout);
begin
  if AWindows = FWindows then Exit;
  FWindows.Free;
  FWindows := AWindows;
end;

procedure TProjectDocument.ReplaceDialogPaths(APaths: TDialogPaths);
begin
  if APaths = FDialogPaths then Exit;
  FDialogPaths.Free;
  FDialogPaths := APaths;
end;

function TProjectDocument.GridContext: TGridContext;
begin
  Result := TGridContext.Make(FTempoBPM, FTimeSigNum, FTimeSigDen, FSampleRate);
  Result.Map := Copy(FTempoMap);
end;

procedure TProjectDocument.MarkDirty;
begin
  FDirty := True;
  FModifiedUTC := Now;
end;

procedure TProjectDocument.Touch;
begin
  MarkDirty;
end;

procedure TProjectDocument.ClearDirty;
begin
  FDirty := False;
end;

procedure TProjectDocument.SetName(const AValue: string);
var
  v: string;
begin
  v := Trim(AValue);
  if v = '' then
    RaiseUDAW(errInvalidArgument, PROJECT_SUBSYS, 'project name cannot be empty');
  if v = FName then Exit;
  FName := v;
  MarkDirty;
end;

procedure TProjectDocument.SetAuthor(const AValue: string);
var
  v: string;
begin
  v := Trim(AValue);
  if v = FAuthor then Exit;
  FAuthor := v;
  MarkDirty;
end;

procedure TProjectDocument.SetTempoBPM(AValue: Double);
begin
  if (AValue < PROJECT_MIN_TEMPO) or (AValue > PROJECT_MAX_TEMPO) then
    RaiseUDAWFmt(errInvalidArgument, PROJECT_SUBSYS,
      'tempo %.3f BPM out of range [%.0f, %.0f]',
      [AValue, PROJECT_MIN_TEMPO, PROJECT_MAX_TEMPO]);
  if SameValue(AValue, FTempoBPM, 1e-9) then Exit;
  FTempoBPM := AValue;
  MarkDirty;
end;

procedure TProjectDocument.SetTempoMap(const AValue: TTempoPoints);
var
  clean: TTempoPoints;
  i, j, n: Integer;
  p: TTempoPoint;
  same: Boolean;
begin
  { keep only points after time 0, clamp the tempo, sort by time, drop duplicates }
  SetLength(clean, 0);
  for i := 0 to High(AValue) do
  begin
    p := AValue[i];
    if p.Seconds < 0.001 then Continue;
    p.Bpm := EnsureRange(p.Bpm, PROJECT_MIN_TEMPO, PROJECT_MAX_TEMPO);
    n := Length(clean);
    SetLength(clean, n + 1);
    j := n;
    while (j > 0) and (clean[j - 1].Seconds > p.Seconds) do
    begin
      clean[j] := clean[j - 1];
      Dec(j);
    end;
    clean[j] := p;
  end;
  j := 0;
  for i := 0 to High(clean) do
    if (j = 0) or (clean[i].Seconds - clean[j - 1].Seconds >= 0.001) then
    begin
      clean[j] := clean[i];
      Inc(j);
    end;
  SetLength(clean, j);
  same := Length(clean) = Length(FTempoMap);
  if same then
    for i := 0 to High(clean) do
      if not (SameValue(clean[i].Seconds, FTempoMap[i].Seconds, 1e-9) and
              SameValue(clean[i].Bpm, FTempoMap[i].Bpm, 1e-9)) then
      begin
        same := False;
        Break;
      end;
  if same then Exit;
  FTempoMap := clean;
  MarkDirty;
end;

procedure TProjectDocument.SetTimeSigNum(AValue: Integer);
begin
  if (AValue < 1) or (AValue > 64) then
    RaiseUDAWFmt(errInvalidArgument, PROJECT_SUBSYS,
      'time signature numerator %d out of range [1, 64]', [AValue]);
  if AValue = FTimeSigNum then Exit;
  FTimeSigNum := AValue;
  MarkDirty;
end;

procedure TProjectDocument.SetTimeSigDen(AValue: Integer);
begin
  if not (AValue in [1, 2, 4, 8, 16, 32, 64]) then
    RaiseUDAWFmt(errInvalidArgument, PROJECT_SUBSYS,
      'time signature denominator %d must be a power of two (1..64)', [AValue]);
  if AValue = FTimeSigDen then Exit;
  FTimeSigDen := AValue;
  MarkDirty;
end;

procedure TProjectDocument.SetSampleRate(AValue: Integer);
begin
  if (AValue < 8000) or (AValue > 384000) then
    RaiseUDAWFmt(errInvalidArgument, PROJECT_SUBSYS,
      'sample rate %d Hz out of supported range [8000, 384000]', [AValue]);
  if AValue = FSampleRate then Exit;
  FSampleRate := AValue;
  MarkDirty;
end;

procedure TProjectDocument.SetChannels(AValue: Integer);
begin
  if (AValue < 1) or (AValue > 32) then
    RaiseUDAWFmt(errInvalidArgument, PROJECT_SUBSYS,
      'channel count %d out of range [1, 32]', [AValue]);
  if AValue = FChannels then Exit;
  FChannels := AValue;
  MarkDirty;
end;

function TProjectDocument.Describe: string;
begin
  Result := Format(
    'project "%s"'#13#10 +
    '  uuid      : %s'#13#10 +
    '  tempo     : %.3f BPM'#13#10 +
    '  time sig  : %d/%d'#13#10 +
    '  format    : %d Hz, %d ch'#13#10 +
    '  created   : %s'#13#10 +
    '  modified  : %s'#13#10 +
    '  file      : %s'#13#10 +
    '  dirty     : %s'#13#10 +
    '  timeline  : %d track(s), %d clip(s), %.3f s'#13#10 +
    '  mixer     : %d strip(s)'#13#10 +
    '  tracker   : %d pattern(s), %d instrument(s)'#13#10 +
    '  midi      : %d clip(s), %d note(s)'#13#10 +
    '  ai spec   : %d section(s), %d track(s), %d lyric section(s)'#13#10 +
    '  %s',
    [FName, GUIDToString(FUUID), FTempoBPM, FTimeSigNum, FTimeSigDen,
     FSampleRate, FChannels, DateTimeToStr(FCreatedUTC), DateTimeToStr(FModifiedUTC),
     FFileName, BoolToStr(FDirty, True),
     FTimeline.TrackCount, FTimeline.ClipCountTotal, FTimeline.TotalDurationSeconds,
     FMixer.StripCount,
     FTracker.PatternCount, FTracker.InstrumentCount,
     FMidi.ClipCount, FMidi.TotalNoteCount,
     FSongSpec.Sections.Count, FSongSpec.Tracks.Count, FLyrics.Sections.Count,
     FGraph.Describe]);
end;

end.
