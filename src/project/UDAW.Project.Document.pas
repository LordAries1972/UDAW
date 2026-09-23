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
  UDAW.MIDI.Serialization,
  UDAW.Composer.SongSpec, UDAW.Composer.Lyrics,
  UDAW.Project.WindowLayout;

const
  PROJECT_SUBSYS = 'Project';

  PROJECT_DEFAULT_TEMPO      = 120.0;
  PROJECT_MIN_TEMPO          = 20.0;
  PROJECT_MAX_TEMPO          = 999.0;
  PROJECT_DEFAULT_TSIG_NUM   = 4;
  PROJECT_DEFAULT_TSIG_DEN   = 4;
  PROJECT_DEFAULT_NAME       = 'Untitled Project';

type
  TProjectDocument = class
  private
    FUUID: TGUID;
    FName: string;
    FAuthor: string;
    FTempoBPM: Double;
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
    FTracker: TTrackerModule;
    FMidi: TMidiProject;
    FSongSpec: TSongSpec;
    FLyrics: TLyricDocument;
    FWindows: TWindowLayout;
    procedure SetName(const AValue: string);
    procedure SetAuthor(const AValue: string);
    procedure SetTempoBPM(AValue: Double);
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
    { Adopts a freshly-parsed tracker module, freeing the current one. Used
      only by the deserializer - normal code edits Tracker via commands. }
    procedure ReplaceTracker(ATracker: TTrackerModule);
    { Adopts a freshly-parsed MIDI project, freeing the current one. Used only
      by the deserializer - normal code edits Midi via commands. }
    procedure ReplaceMidi(AMidi: TMidiProject);
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
    { The tempo / time-signature / sample-rate context timeline math needs. }
    function GridContext: TGridContext;

    property UUID: TGUID read FUUID write FUUID;
    property Name: string read FName write SetName;
    { Author / artist name stamped into MP3/MP4/M4A exports. May be empty. }
    property Author: string read FAuthor write SetAuthor;
    property TempoBPM: Double read FTempoBPM write SetTempoBPM;
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
    property Tracker: TTrackerModule read FTracker;
    property Midi: TMidiProject read FMidi;
    property SongSpec: TSongSpec read FSongSpec;
    property Lyrics: TLyricDocument read FLyrics;
    property Windows: TWindowLayout read FWindows;

    function Describe: string;
  end;

implementation

constructor TProjectDocument.Create;
begin
  inherited Create;
  CreateGUID(FUUID);
  FName := PROJECT_DEFAULT_NAME;
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
  FTracker := TTrackerModule.Create;
  FMidi := TMidiProject.Create;
  FSongSpec := TSongSpec.Create;
  FLyrics := TLyricDocument.Create;
  FWindows := TWindowLayout.Create;
end;

constructor TProjectDocument.CreateNew(const AName: string);
begin
  Create;
  if Trim(AName) <> '' then
    FName := Trim(AName);
  FGraph.AddNode(nkOutput, 'Master');
  FMixer.InitDefault;
  FTracker.InitDefault;
end;

destructor TProjectDocument.Destroy;
begin
  FWindows.Free;
  FLyrics.Free;
  FSongSpec.Free;
  FMidi.Free;
  FTracker.Free;
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
  Result.FTempoBPM := FTempoBPM;
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

  Result.FTracker.Free;
  Result.FTracker := FTracker.Clone;

  Result.FMidi.Free;
  Result.FMidi := FMidi.Clone;

  Result.FSongSpec.Free;
  Result.FSongSpec := FSongSpec.Clone;

  Result.FLyrics.Free;
  Result.FLyrics := FLyrics.Clone;

  Result.FWindows.Free;
  Result.FWindows := FWindows.Clone;
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

function TProjectDocument.GridContext: TGridContext;
begin
  Result := TGridContext.Make(FTempoBPM, FTimeSigNum, FTimeSigDen, FSampleRate);
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
