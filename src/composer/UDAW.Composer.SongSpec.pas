unit UDAW.Composer.SongSpec;
{$I udaw.inc}

{ AI Composition, Phase 1 - Internal Data Model (docs/AIPlan.md section 17,
  "PHASE 1 - INTERNAL DATA MODEL").

  TSongSpec is the Structured Song Specification the whole AI-composition
  pipeline revolves around (AIPlan.md section 1's "safe, predictable
  contract between the AI and the DAW", section 5's JSON shape). It is a
  plain, GUI/AI/network-free in-memory model - the AI provider layer
  (a later phase) fills one in from a provider response; the validator
  (UDAW.Composer.Validation) checks it; the arrangement engine (a later
  phase) reads it to build the real Timeline/MIDI/Mixer content. Nothing
  here talks to a provider, a file, or the timeline.

  Every class follows the project's existing per-subsystem-root style
  (TTimeline, TMixerModel, TMidiProject): a Clone method for the undo
  commands and project Clone/recovery path, and TObjectList-owned children.
  Note/clip/automation storage is NOT duplicated here - once a track is
  realised, its notes live in TMidiSequence (UDAW.MIDI.Sequence) and its
  automation in TAutomationSet (UDAW.Mixer.Automation), exactly as for any
  other track; TSongSpec only carries the AI's musical INTENT for a track,
  never generated notes. }

interface

uses
  SysUtils, Generics.Collections,
  UDAW.Errors;

const
  COMPOSER_SUBSYS = 'Composer.SongSpec';

type
  TSongTrackKind = (stkMidi, stkAudio, stkBus);

  { AIPlan.md section 5: project.* }
  TSongMeta = class
  private
    FTitle: string;
    FInstrumental: Boolean;
    FTempo: Double;
    FKey: string;
    FScale: string;
    FTimeSigNum: Integer;
    FTimeSigDen: Integer;
    FDurationBars: Integer;
  public
    constructor Create;
    function Clone: TSongMeta;
    property Title: string read FTitle write FTitle;
    property Instrumental: Boolean read FInstrumental write FInstrumental;
    property Tempo: Double read FTempo write FTempo;
    property Key: string read FKey write FKey;
    property Scale: string read FScale write FScale;
    property TimeSigNum: Integer read FTimeSigNum write FTimeSigNum;
    property TimeSigDen: Integer read FTimeSigDen write FTimeSigDen;
    property DurationBars: Integer read FDurationBars write FDurationBars;
  end;

  { AIPlan.md section 5: sections[] }
  TSongSection = class
  private
    FId: string;
    FName: string;
    FStartBar: Integer;
    FLengthBars: Integer;
    FEnergy: Double;
    FLocked: Boolean;
  public
    constructor Create(const AId: string = ''; const AName: string = '';
      AStartBar: Integer = 1; ALengthBars: Integer = 4; AEnergy: Double = 0.5);
    function Clone: TSongSection;
    function EndBarExclusive: Integer; // StartBar + LengthBars
    property Id: string read FId write FId;
    property Name: string read FName write FName;
    property StartBar: Integer read FStartBar write FStartBar;
    property LengthBars: Integer read FLengthBars write FLengthBars;
    property Energy: Double read FEnergy write FEnergy;
    { AIPlan.md section 17 PHASE 8 "Preserve locked content": a revision
      request must never modify a section the user has locked, no matter
      what the AI returns for it - see UDAW.AI.Composer.MergeLockedAndOutOfScope. }
    property Locked: Boolean read FLocked write FLocked;
  end;

  { AIPlan.md section 5: tracks[] - musical INTENT for a track, not its
    realised content. requestedTags/preferredInstrumentId/fallbackCategory
    feed the (later-phase) instrument resolver against the Phase 2
    catalogue; never store a raw file path here. }
  TSongTrackSpec = class
  private
    FId: string;
    FName: string;
    FKind: TSongTrackKind;
    FRole: string;
    FRequestedTags: TArray<string>;
    FPreferredInstrumentId: string;
    FFallbackCategory: string;
    FMidiChannel: Integer;
    FLocked: Boolean;
    FRequireMidi: Boolean;
  public
    constructor Create(const AId: string = ''; const AName: string = '';
      AKind: TSongTrackKind = stkMidi; const ARole: string = '');
    function Clone: TSongTrackSpec;
    property Id: string read FId write FId;
    property Name: string read FName write FName;
    property Kind: TSongTrackKind read FKind write FKind;
    property Role: string read FRole write FRole;
    property RequestedTags: TArray<string> read FRequestedTags write FRequestedTags;
    property PreferredInstrumentId: string read FPreferredInstrumentId write FPreferredInstrumentId;
    property FallbackCategory: string read FFallbackCategory write FFallbackCategory;
    property MidiChannel: Integer read FMidiChannel write FMidiChannel;
    { AIPlan.md section 9/10: samples and loops are the default realisation
      for a track; generated MIDI is only used when the user's request (or an
      instrument that genuinely needs performance data, e.g. a specific synth
      patch) explicitly calls for it. False (the default) lets the
      arrangement engine substitute a matching sample/loop for a stkMidi
      track's generated notes; True pins the track to real MIDI generation
      regardless of what the catalogue offers. Meaningless for stkAudio/
      stkBus tracks, which never generate MIDI to begin with. }
    property RequireMidi: Boolean read FRequireMidi write FRequireMidi;
    { AIPlan.md section 17 PHASE 8 "Preserve locked content" - see
      TSongSection.Locked. }
    property Locked: Boolean read FLocked write FLocked;
  end;

  { AIPlan.md section 5: harmony.chordProgressions[] }
  TChordProgressionEntry = class
  private
    FSectionId: string;
    FChords: TArray<string>;
    FBarsPerChord: Integer;
  public
    constructor Create(const ASectionId: string = ''; ABarsPerChord: Integer = 1);
    function Clone: TChordProgressionEntry;
    { Total bars this progression spans: Length(Chords) * BarsPerChord. }
    function TotalBars: Integer;
    property SectionId: string read FSectionId write FSectionId;
    property Chords: TArray<string> read FChords write FChords;
    property BarsPerChord: Integer read FBarsPerChord write FBarsPerChord;
  end;

  { The top-level Structured Song Specification (AIPlan.md section 5) plus
    the provenance fields section 14 says every project must retain
    ("Original user request", "Provider used", "Model identifier", ...
    "Generation seed"). API keys are never stored here (section 14) - only
    the provider id / model id strings. }
  TSongSpec = class
  private
    FMeta: TSongMeta;
    FSections: TObjectList<TSongSection>;
    FTracks: TObjectList<TSongTrackSpec>;
    FHarmony: TObjectList<TChordProgressionEntry>;
    FOriginalRequest: string;
    FProviderId: string;
    FModelId: string;
    FGenerationSeed: Int64;
  public
    constructor Create;
    destructor Destroy; override;
    function Clone: TSongSpec;
    procedure Clear;

    function AddSection(ASection: TSongSection): TSongSection;   // takes ownership
    function SectionById(const AId: string): TSongSection;
    function AddTrack(ATrack: TSongTrackSpec): TSongTrackSpec;    // takes ownership
    function TrackById(const AId: string): TSongTrackSpec;
    function AddChordProgression(AEntry: TChordProgressionEntry): TChordProgressionEntry; // takes ownership

    property Meta: TSongMeta read FMeta;
    property Sections: TObjectList<TSongSection> read FSections;
    property Tracks: TObjectList<TSongTrackSpec> read FTracks;
    property Harmony: TObjectList<TChordProgressionEntry> read FHarmony;
    property OriginalRequest: string read FOriginalRequest write FOriginalRequest;
    property ProviderId: string read FProviderId write FProviderId;
    property ModelId: string read FModelId write FModelId;
    property GenerationSeed: Int64 read FGenerationSeed write FGenerationSeed;
  end;

implementation

{ TSongMeta }

constructor TSongMeta.Create;
begin
  inherited Create;
  FTitle := 'Untitled Song';
  FInstrumental := False;
  FTempo := 120.0;
  FKey := 'C';
  FScale := 'major';
  FTimeSigNum := 4;
  FTimeSigDen := 4;
  FDurationBars := 32;
end;

function TSongMeta.Clone: TSongMeta;
begin
  Result := TSongMeta.Create;
  Result.FTitle := FTitle;
  Result.FInstrumental := FInstrumental;
  Result.FTempo := FTempo;
  Result.FKey := FKey;
  Result.FScale := FScale;
  Result.FTimeSigNum := FTimeSigNum;
  Result.FTimeSigDen := FTimeSigDen;
  Result.FDurationBars := FDurationBars;
end;

{ TSongSection }

constructor TSongSection.Create(const AId, AName: string; AStartBar, ALengthBars: Integer;
  AEnergy: Double);
begin
  inherited Create;
  FId := AId;
  FName := AName;
  FStartBar := AStartBar;
  FLengthBars := ALengthBars;
  FEnergy := AEnergy;
end;

function TSongSection.Clone: TSongSection;
begin
  Result := TSongSection.Create(FId, FName, FStartBar, FLengthBars, FEnergy);
  Result.FLocked := FLocked;
end;

function TSongSection.EndBarExclusive: Integer;
begin
  Result := FStartBar + FLengthBars;
end;

{ TSongTrackSpec }

constructor TSongTrackSpec.Create(const AId, AName: string; AKind: TSongTrackKind;
  const ARole: string);
begin
  inherited Create;
  FId := AId;
  FName := AName;
  FKind := AKind;
  FRole := ARole;
  FMidiChannel := -1; // unassigned
end;

function TSongTrackSpec.Clone: TSongTrackSpec;
begin
  Result := TSongTrackSpec.Create(FId, FName, FKind, FRole);
  Result.FRequestedTags := Copy(FRequestedTags);
  Result.FPreferredInstrumentId := FPreferredInstrumentId;
  Result.FFallbackCategory := FFallbackCategory;
  Result.FMidiChannel := FMidiChannel;
  Result.FLocked := FLocked;
  Result.FRequireMidi := FRequireMidi;
end;

{ TChordProgressionEntry }

constructor TChordProgressionEntry.Create(const ASectionId: string; ABarsPerChord: Integer);
begin
  inherited Create;
  FSectionId := ASectionId;
  FBarsPerChord := ABarsPerChord;
end;

function TChordProgressionEntry.Clone: TChordProgressionEntry;
begin
  Result := TChordProgressionEntry.Create(FSectionId, FBarsPerChord);
  Result.FChords := Copy(FChords);
end;

function TChordProgressionEntry.TotalBars: Integer;
begin
  Result := Length(FChords) * FBarsPerChord;
end;

{ TSongSpec }

constructor TSongSpec.Create;
begin
  inherited Create;
  FMeta := TSongMeta.Create;
  FSections := TObjectList<TSongSection>.Create(True);
  FTracks := TObjectList<TSongTrackSpec>.Create(True);
  FHarmony := TObjectList<TChordProgressionEntry>.Create(True);
  FGenerationSeed := 0;
end;

destructor TSongSpec.Destroy;
begin
  FHarmony.Free;
  FTracks.Free;
  FSections.Free;
  FMeta.Free;
  inherited Destroy;
end;

procedure TSongSpec.Clear;
begin
  FSections.Clear;
  FTracks.Clear;
  FHarmony.Clear;
  FOriginalRequest := '';
  FProviderId := '';
  FModelId := '';
  FGenerationSeed := 0;
end;

function TSongSpec.Clone: TSongSpec;
var
  i: Integer;
begin
  Result := TSongSpec.Create;
  Result.FMeta.Free;
  Result.FMeta := FMeta.Clone;
  for i := 0 to FSections.Count - 1 do
    Result.FSections.Add(FSections[i].Clone);
  for i := 0 to FTracks.Count - 1 do
    Result.FTracks.Add(FTracks[i].Clone);
  for i := 0 to FHarmony.Count - 1 do
    Result.FHarmony.Add(FHarmony[i].Clone);
  Result.FOriginalRequest := FOriginalRequest;
  Result.FProviderId := FProviderId;
  Result.FModelId := FModelId;
  Result.FGenerationSeed := FGenerationSeed;
end;

function TSongSpec.AddSection(ASection: TSongSection): TSongSection;
begin
  FSections.Add(ASection);
  Result := ASection;
end;

function TSongSpec.SectionById(const AId: string): TSongSection;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FSections.Count - 1 do
    if SameText(FSections[i].Id, AId) then Exit(FSections[i]);
end;

function TSongSpec.AddTrack(ATrack: TSongTrackSpec): TSongTrackSpec;
begin
  FTracks.Add(ATrack);
  Result := ATrack;
end;

function TSongSpec.TrackById(const AId: string): TSongTrackSpec;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FTracks.Count - 1 do
    if SameText(FTracks[i].Id, AId) then Exit(FTracks[i]);
end;

function TSongSpec.AddChordProgression(AEntry: TChordProgressionEntry): TChordProgressionEntry;
begin
  FHarmony.Add(AEntry);
  Result := AEntry;
end;

end.
