unit UDAW.Pattern.Model;
{$I udaw.inc}

{ Rhythm patterns: the data behind the Pattern editor (a step grid).

  A TPattern is a number of steps (rows of the grid) at a resolution of
  StepsPerBeat (2 = 1/8, 4 = 1/16, 8 = 1/32), and one lane per instrument. A lane
  names the instrument - a MIDI note (the drum machine's pad), its display name and
  the sample on that pad - so a pattern carries the instruments it uses, and holds
  one velocity per step (0 = no hit).

  TPatternLibrary owns every pattern of a project. It is saved in the project file
  (the PATTERNS block, see UDAW.Project.Serialization) and a single pattern can be
  exported as a preset (PatternToPreset / PatternFromPreset).

  A pattern reaches the Timeline as a MIDI clip: ToMidi renders it to channel-10
  notes, which the drum machine plays. The pattern remembers that clip's id
  (MidiClipId) so editing the pattern re-renders every instance placed on the
  Timeline. }

interface

uses
  SysUtils, Classes, Math, Generics.Collections,
  UDAW.Errors, UDAW.MIDI.Types, UDAW.MIDI.Sequence;

const
  PATTERN_MAGIC = 'UDAWPATTERNS';
  PATTERN_VERSION = 1;
  PATTERN_SUBSYS = 'Pattern';
  PATTERN_MAX_STEPS = 512;
  PATTERN_DEFAULT_STEPS = 32;
  PATTERN_DEFAULT_VELOCITY = 100;
  PATTERN_DRUM_CHANNEL = 9;      // MIDI channel 10, 0-based: the drum machine

type
  TPatternLane = class
  public
    Note: Integer;               // MIDI note = drum pad
    Name: string;                // instrument name
    SamplePath: string;          // the sample on that pad when the pattern was saved
    Muted: Boolean;
    Steps: TArray<Byte>;         // velocity per step, 0 = off
    function Clone: TPatternLane;
    function HitCount: Integer;
  end;

  TPattern = class
  private
    FLanes: TObjectList<TPatternLane>;
    FStepCount: Integer;
    function GetLane(AIndex: Integer): TPatternLane;
    function GetLaneCount: Integer;
    procedure SetStepCount(AValue: Integer);
  public
    Id: Integer;
    Name: string;
    StepsPerBeat: Integer;       // 2 = 1/8, 4 = 1/16, 8 = 1/32
    MidiClipId: Integer;         // the MIDI-library clip rendered from this pattern, 0 = none yet
    constructor Create;
    destructor Destroy; override;
    function Clone: TPattern;
    function AddLane(ANote: Integer; const AName, ASamplePath: string): TPatternLane;
    function LaneForNote(ANote: Integer): Integer;       // -1 if none
    procedure RemoveLane(AIndex: Integer);
    function Velocity(ALane, AStep: Integer): Integer;
    procedure SetVelocity(ALane, AStep, AVelocity: Integer);
    { every AEvery-th step starting at AOffset (ALane < 0: every lane) }
    procedure Fill(ALane, AEvery, AOffset, AVelocity: Integer);
    { APulses hits spread evenly over the steps, rotated by ARotate }
    procedure Euclidean(ALane, APulses, ARotate, AVelocity: Integer);
    { shifts the steps by ADelta, wrapping (ALane < 0: every lane) }
    procedure Rotate(ALane, ADelta: Integer);
    procedure Randomize(ALane: Integer; ADensity: Double; ASeed: Cardinal);
    procedure ClearSteps(ALane: Integer);                // ALane < 0: every lane
    { re-grids the pattern to ANewSpb steps per beat, keeping every hit in time where
      the new grid can hold it }
    procedure ChangeResolution(ANewSpb: Integer);
    function DurationBeats: Double;
    function TotalHits: Integer;
    function ToMidi(APPQ: Integer; ABpm: Double): TMidiSequence;   // caller owns it
    function DurationSeconds(ABpm: Double): Double;
    property StepCount: Integer read FStepCount write SetStepCount;
    property LaneCount: Integer read GetLaneCount;
    property Lanes[AIndex: Integer]: TPatternLane read GetLane;
  end;

  TPatternLibrary = class
  private
    FPatterns: TObjectList<TPattern>;
    FNextId: Integer;
    function GetCount: Integer;
    function GetPattern(AIndex: Integer): TPattern;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    { adopts APattern and gives it a fresh stable id; returns the index }
    function Add(APattern: TPattern): Integer;
    function NewPattern(const ABaseName: string): TPattern;
    function IndexOfId(AId: Integer): Integer;           // -1 if none
    function ById(AId: Integer): TPattern;               // nil if none
    function ByMidiClip(AMidiClipId: Integer): TPattern; // nil if none
    procedure Remove(AIndex: Integer);
    function UniqueName(const ABase: string): string;
    function Clone: TPatternLibrary;
    property Count: Integer read GetCount;
    property Patterns[AIndex: Integer]: TPattern read GetPattern; default;
    property NextId: Integer read FNextId write FNextId;
  end;

{ the text codec the project file embeds between PATTERNS-BEGIN / PATTERNS-END }
function PatternLibraryToString(ALib: TPatternLibrary): string;
function PatternLibraryFromString(const AText: string): TPatternLibrary;   // caller owns it
{ one pattern, for a preset file }
function PatternToPreset(APattern: TPattern): string;
function PatternFromPreset(const AText: string): TPattern;                 // caller owns it; Id 0

function PatternResolutionName(ASpb: Integer): string;   // '1/16'

implementation

function PatternResolutionName(ASpb: Integer): string;
begin
  case ASpb of
    1: Result := '1/4';
    2: Result := '1/8';
    4: Result := '1/16';
    8: Result := '1/32';
  else
    Result := '1/' + IntToStr(ASpb * 4);
  end;
end;

{ ============================ TPatternLane ======================= }

function TPatternLane.Clone: TPatternLane;
begin
  Result := TPatternLane.Create;
  Result.Note := Note;
  Result.Name := Name;
  Result.SamplePath := SamplePath;
  Result.Muted := Muted;
  Result.Steps := Copy(Steps);
end;

function TPatternLane.HitCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(Steps) do
    if Steps[i] > 0 then Inc(Result);
end;

{ ============================ TPattern =========================== }

constructor TPattern.Create;
begin
  inherited Create;
  FLanes := TObjectList<TPatternLane>.Create(True);
  FStepCount := PATTERN_DEFAULT_STEPS;
  StepsPerBeat := 4;
  Name := 'Pattern';
end;

destructor TPattern.Destroy;
begin
  FLanes.Free;
  inherited Destroy;
end;

function TPattern.GetLane(AIndex: Integer): TPatternLane;
begin
  Result := FLanes[AIndex];
end;

function TPattern.GetLaneCount: Integer;
begin
  Result := FLanes.Count;
end;

procedure TPattern.SetStepCount(AValue: Integer);
var
  i: Integer;
begin
  AValue := EnsureRange(AValue, 1, PATTERN_MAX_STEPS);
  if AValue = FStepCount then Exit;
  FStepCount := AValue;
  for i := 0 to FLanes.Count - 1 do
    SetLength(FLanes[i].Steps, FStepCount);   // grows with zeros, shrinks by cutting
end;

function TPattern.Clone: TPattern;
var
  i: Integer;
begin
  Result := TPattern.Create;
  Result.Id := Id;
  Result.Name := Name;
  Result.StepsPerBeat := StepsPerBeat;
  Result.MidiClipId := MidiClipId;
  Result.FStepCount := FStepCount;
  for i := 0 to FLanes.Count - 1 do
    Result.FLanes.Add(FLanes[i].Clone);
end;

function TPattern.AddLane(ANote: Integer; const AName, ASamplePath: string): TPatternLane;
begin
  Result := TPatternLane.Create;
  Result.Note := EnsureRange(ANote, 0, 127);
  Result.Name := AName;
  Result.SamplePath := ASamplePath;
  SetLength(Result.Steps, FStepCount);
  FLanes.Add(Result);
end;

function TPattern.LaneForNote(ANote: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to FLanes.Count - 1 do
    if FLanes[i].Note = ANote then Exit(i);
  Result := -1;
end;

procedure TPattern.RemoveLane(AIndex: Integer);
begin
  if (AIndex >= 0) and (AIndex < FLanes.Count) then FLanes.Delete(AIndex);
end;

function TPattern.Velocity(ALane, AStep: Integer): Integer;
begin
  if (ALane < 0) or (ALane >= FLanes.Count) or (AStep < 0) or (AStep >= FStepCount) then Exit(0);
  Result := FLanes[ALane].Steps[AStep];
end;

procedure TPattern.SetVelocity(ALane, AStep, AVelocity: Integer);
begin
  if (ALane < 0) or (ALane >= FLanes.Count) or (AStep < 0) or (AStep >= FStepCount) then Exit;
  FLanes[ALane].Steps[AStep] := EnsureRange(AVelocity, 0, 127);
end;

procedure TPattern.Fill(ALane, AEvery, AOffset, AVelocity: Integer);
var
  l, s: Integer;
begin
  AEvery := Max(1, AEvery);
  for l := 0 to FLanes.Count - 1 do
  begin
    if (ALane >= 0) and (l <> ALane) then Continue;
    s := Max(0, AOffset);
    while s < FStepCount do
    begin
      FLanes[l].Steps[s] := EnsureRange(AVelocity, 1, 127);
      Inc(s, AEvery);
    end;
  end;
end;

procedure TPattern.Euclidean(ALane, APulses, ARotate, AVelocity: Integer);
var
  s, k: Integer;
begin
  if (ALane < 0) or (ALane >= FLanes.Count) then Exit;
  APulses := EnsureRange(APulses, 0, FStepCount);
  for s := 0 to FStepCount - 1 do FLanes[ALane].Steps[s] := 0;
  if APulses = 0 then Exit;
  { Bjorklund by accumulation: step s is a hit when the running total crosses a whole number }
  for k := 0 to APulses - 1 do
  begin
    s := (Trunc(k * FStepCount / APulses) + ARotate) mod FStepCount;
    if s < 0 then Inc(s, FStepCount);
    FLanes[ALane].Steps[s] := EnsureRange(AVelocity, 1, 127);
  end;
end;

procedure TPattern.Rotate(ALane, ADelta: Integer);
var
  l, s, d: Integer;
  src: TArray<Byte>;
begin
  d := ADelta mod FStepCount;
  if d = 0 then Exit;
  for l := 0 to FLanes.Count - 1 do
  begin
    if (ALane >= 0) and (l <> ALane) then Continue;
    src := Copy(FLanes[l].Steps);
    for s := 0 to FStepCount - 1 do
      FLanes[l].Steps[((s + d) mod FStepCount + FStepCount) mod FStepCount] := src[s];
  end;
end;

procedure TPattern.Randomize(ALane: Integer; ADensity: Double; ASeed: Cardinal);
var
  l, s: Integer;
  state: Cardinal;
  function Next: Double;
  begin
    state := Cardinal((UInt64(state) * 1664525 + 1013904223) and $FFFFFFFF);
    Result := (state shr 8) / 16777216.0;
  end;
begin
  state := ASeed;
  for l := 0 to FLanes.Count - 1 do
  begin
    if (ALane >= 0) and (l <> ALane) then Continue;
    for s := 0 to FStepCount - 1 do
      if Next < ADensity then
        FLanes[l].Steps[s] := EnsureRange(70 + Round(Next * 57), 1, 127)
      else
        FLanes[l].Steps[s] := 0;
  end;
end;

procedure TPattern.ClearSteps(ALane: Integer);
var
  l, s: Integer;
begin
  for l := 0 to FLanes.Count - 1 do
  begin
    if (ALane >= 0) and (l <> ALane) then Continue;
    for s := 0 to FStepCount - 1 do FLanes[l].Steps[s] := 0;
  end;
end;

procedure TPattern.ChangeResolution(ANewSpb: Integer);
var
  l, s, target, newCount: Integer;
  src: TArray<Byte>;
  dst: TArray<Byte>;
begin
  ANewSpb := EnsureRange(ANewSpb, 1, 16);
  if ANewSpb = StepsPerBeat then Exit;
  newCount := EnsureRange(Max(1, Round(FStepCount * ANewSpb / StepsPerBeat)), 1, PATTERN_MAX_STEPS);
  for l := 0 to FLanes.Count - 1 do
  begin
    src := FLanes[l].Steps;
    SetLength(dst, newCount);
    for s := 0 to High(dst) do dst[s] := 0;
    for s := 0 to FStepCount - 1 do
      if src[s] > 0 then
      begin
        target := Trunc(s * ANewSpb / StepsPerBeat);   // the strongest hit wins on a coarser grid
        if target < newCount then dst[target] := Max(dst[target], src[s]);
      end;
    FLanes[l].Steps := dst;
  end;
  FStepCount := newCount;
  StepsPerBeat := ANewSpb;
end;

function TPattern.DurationBeats: Double;
begin
  Result := FStepCount / Max(1, StepsPerBeat);
end;

function TPattern.DurationSeconds(ABpm: Double): Double;
begin
  Result := DurationBeats * 60.0 / Max(20.0, ABpm);
end;

function TPattern.TotalHits: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to FLanes.Count - 1 do Inc(Result, FLanes[i].HitCount);
end;

function TPattern.ToMidi(APPQ: Integer; ABpm: Double): TMidiSequence;
var
  trk: TMidiTrackSeq;
  l, s: Integer;
  stepTicks: Int64;
  n: TMidiNote;
begin
  Result := TMidiSequence.Create(APPQ);
  Result.InitDefault;
  Result.SetInitialBPM(ABpm);
  trk := Result.GetTrack(0);
  trk.Name := Name;
  trk.ChannelHint := PATTERN_DRUM_CHANNEL;
  stepTicks := Max(1, Round(APPQ / Max(1, StepsPerBeat)));
  for s := 0 to FStepCount - 1 do
    for l := 0 to FLanes.Count - 1 do
    begin
      if FLanes[l].Muted or (FLanes[l].Steps[s] = 0) then Continue;
      n := Default(TMidiNote);
      n.Id := Result.NewNoteId;
      n.StartTick := s * stepTicks;
      n.LengthTick := Max(1, stepTicks * 9 div 10);
      n.Channel := PATTERN_DRUM_CHANNEL;
      n.Note := FLanes[l].Note;
      n.Velocity := FLanes[l].Steps[s];
      n.OffVelocity := 0;
      trk.AddNote(n);
    end;
  trk.SortNotes;
end;

{ ============================ TPatternLibrary ==================== }

constructor TPatternLibrary.Create;
begin
  inherited Create;
  FPatterns := TObjectList<TPattern>.Create(True);
  FNextId := 1;
end;

destructor TPatternLibrary.Destroy;
begin
  FPatterns.Free;
  inherited Destroy;
end;

procedure TPatternLibrary.Clear;
begin
  FPatterns.Clear;
end;

function TPatternLibrary.GetCount: Integer;
begin
  Result := FPatterns.Count;
end;

function TPatternLibrary.GetPattern(AIndex: Integer): TPattern;
begin
  Result := FPatterns[AIndex];
end;

function TPatternLibrary.Add(APattern: TPattern): Integer;
begin
  APattern.Id := FNextId;
  Inc(FNextId);
  Result := FPatterns.Add(APattern);
end;

function TPatternLibrary.UniqueName(const ABase: string): string;
var
  n: Integer;
  function Taken(const AName: string): Boolean;
  var
    i: Integer;
  begin
    Result := False;
    for i := 0 to FPatterns.Count - 1 do
      if SameText(FPatterns[i].Name, AName) then Exit(True);
  end;
begin
  Result := ABase;
  if not Taken(Result) then Exit;
  n := 2;
  while Taken(Format('%s %d', [ABase, n])) do Inc(n);
  Result := Format('%s %d', [ABase, n]);
end;

function TPatternLibrary.NewPattern(const ABaseName: string): TPattern;
begin
  Result := TPattern.Create;
  Result.Name := UniqueName(ABaseName);
  Add(Result);
end;

function TPatternLibrary.IndexOfId(AId: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to FPatterns.Count - 1 do
    if FPatterns[i].Id = AId then Exit(i);
  Result := -1;
end;

function TPatternLibrary.ById(AId: Integer): TPattern;
var
  i: Integer;
begin
  i := IndexOfId(AId);
  if i < 0 then Result := nil else Result := FPatterns[i];
end;

function TPatternLibrary.ByMidiClip(AMidiClipId: Integer): TPattern;
var
  i: Integer;
begin
  Result := nil;
  if AMidiClipId = 0 then Exit;
  for i := 0 to FPatterns.Count - 1 do
    if FPatterns[i].MidiClipId = AMidiClipId then Exit(FPatterns[i]);
end;

procedure TPatternLibrary.Remove(AIndex: Integer);
begin
  if (AIndex >= 0) and (AIndex < FPatterns.Count) then FPatterns.Delete(AIndex);
end;

function TPatternLibrary.Clone: TPatternLibrary;
var
  i: Integer;
begin
  Result := TPatternLibrary.Create;
  Result.FNextId := FNextId;
  for i := 0 to FPatterns.Count - 1 do
    Result.FPatterns.Add(FPatterns[i].Clone);
end;

{ ============================ text codec ========================= }

function Q(const S: string): string;
begin
  Result := '"' + StringReplace(StringReplace(S, '"', '''', [rfReplaceAll]), #13#10, ' ', [rfReplaceAll]) + '"';
end;

function TakeQuoted(var S: string): string;
var
  i, closeAt: Integer;
begin
  S := TrimLeft(S);
  if (S = '') or (S[1] <> '"') then
    RaiseUDAW(errConfig, PATTERN_SUBSYS, 'pattern parse: expected a quoted value');
  closeAt := 0;
  for i := 2 to Length(S) do
    if S[i] = '"' then begin closeAt := i; Break; end;
  if closeAt = 0 then
    RaiseUDAW(errConfig, PATTERN_SUBSYS, 'pattern parse: unterminated quoted value');
  Result := Copy(S, 2, closeAt - 2);
  S := TrimLeft(Copy(S, closeAt + 1, MaxInt));
end;

function Tok(var S: string): string;
var
  sp: Integer;
begin
  S := TrimLeft(S);
  sp := Pos(' ', S);
  if sp = 0 then begin Result := S; S := ''; end
  else begin Result := Copy(S, 1, sp - 1); S := TrimLeft(Copy(S, sp + 1, MaxInt)); end;
end;

function I32(const S: string): Integer;
begin
  if not TryStrToInt(Trim(S), Result) then
    RaiseUDAWFmt(errConfig, PATTERN_SUBSYS, 'pattern parse: "%s" is not an integer', [S]);
end;

procedure AppendPattern(ASb: TStringBuilder; APat: TPattern; AWithId: Boolean);
var
  l, s: Integer;
  lane: TPatternLane;
begin
  ASb.Append('PATTERN ').Append(IfThen(AWithId, APat.Id, 0)).Append(' ').Append(Q(APat.Name))
    .Append(' SPB ').Append(APat.StepsPerBeat)
    .Append(' STEPS ').Append(APat.StepCount)
    .Append(' MIDI ').Append(IfThen(AWithId, APat.MidiClipId, 0)).AppendLine;
  for l := 0 to APat.LaneCount - 1 do
  begin
    lane := APat.Lanes[l];
    ASb.Append('LANE ').Append(lane.Note).Append(' ').Append(Q(lane.Name)).Append(' ')
      .Append(Q(lane.SamplePath)).Append(' ').Append(Ord(lane.Muted)).AppendLine;
    ASb.Append('VEL');
    for s := 0 to APat.StepCount - 1 do
      ASb.Append(' ').Append(lane.Steps[s]);
    ASb.AppendLine;
  end;
  ASb.Append('ENDPATTERN').AppendLine;
end;

function PatternLibraryToString(ALib: TPatternLibrary): string;
var
  sb: TStringBuilder;
  i: Integer;
begin
  sb := TStringBuilder.Create;
  try
    sb.Append(PATTERN_MAGIC).Append(' ').Append(PATTERN_VERSION).AppendLine;
    sb.Append('NEXTID ').Append(ALib.NextId).AppendLine;
    for i := 0 to ALib.Count - 1 do
      AppendPattern(sb, ALib[i], True);
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

{ parses the lines of one PATTERN ... ENDPATTERN block; ALines[AIdx] is the PATTERN line }
function ParsePattern(ALines: TStrings; var AIdx: Integer): TPattern;
var
  line, t, key: string;
  lane: TPatternLane;
  parts: TArray<string>;
  s, v, steps: Integer;
begin
  Result := TPattern.Create;
  try
    line := Trim(ALines[AIdx]);
    Tok(line);                                // PATTERN
    Result.Id := I32(Tok(line));
    Result.Name := TakeQuoted(line);
    steps := PATTERN_DEFAULT_STEPS;
    while line <> '' do
    begin
      key := Tok(line);
      t := Tok(line);
      if SameText(key, 'SPB') then Result.StepsPerBeat := EnsureRange(I32(t), 1, 16)
      else if SameText(key, 'STEPS') then steps := EnsureRange(I32(t), 1, PATTERN_MAX_STEPS)
      else if SameText(key, 'MIDI') then Result.MidiClipId := I32(t);
    end;
    Result.StepCount := steps;
    lane := nil;
    Inc(AIdx);
    while AIdx < ALines.Count do
    begin
      line := Trim(ALines[AIdx]);
      Inc(AIdx);
      if line = '' then Continue;
      key := Tok(line);
      if SameText(key, 'ENDPATTERN') then Exit;
      if SameText(key, 'LANE') then
      begin
        v := I32(Tok(line));
        t := TakeQuoted(line);
        lane := Result.AddLane(v, t, TakeQuoted(line));
        lane.Muted := I32(Tok(line)) <> 0;
      end
      else if SameText(key, 'VEL') and (lane <> nil) then
      begin
        parts := line.Split([' '], TStringSplitOptions.ExcludeEmpty);
        for s := 0 to Min(High(parts), Result.StepCount - 1) do
          lane.Steps[s] := EnsureRange(StrToIntDef(parts[s], 0), 0, 127);
      end;
    end;
    RaiseUDAW(errConfig, PATTERN_SUBSYS, 'PATTERN without a matching ENDPATTERN');
  except
    Result.Free;
    raise;
  end;
end;

function PatternLibraryFromString(const AText: string): TPatternLibrary;
var
  lines: TStringList;
  i, ver: Integer;
  line, key: string;
  pat: TPattern;
begin
  Result := TPatternLibrary.Create;
  lines := TStringList.Create;
  try
    lines.Text := AText;
    i := 0;
    while (i < lines.Count) and (Trim(lines[i]) = '') do Inc(i);
    if i >= lines.Count then Exit;           // an empty block is an empty library
    line := Trim(lines[i]);
    Inc(i);
    if not SameText(Tok(line), PATTERN_MAGIC) then
      RaiseUDAW(errConfig, PATTERN_SUBSYS, 'not a pattern document');
    ver := I32(Tok(line));
    if (ver <= 0) or (ver > PATTERN_VERSION) then
      RaiseUDAWFmt(errConfig, PATTERN_SUBSYS, 'unsupported pattern document version %d', [ver]);
    while i < lines.Count do
    begin
      line := Trim(lines[i]);
      if line = '' then begin Inc(i); Continue; end;
      key := Copy(line, 1, Pos(' ', line + ' ') - 1);
      if SameText(key, 'NEXTID') then
      begin
        Tok(line);
        Result.FNextId := Max(1, I32(Tok(line)));
        Inc(i);
      end
      else if SameText(key, 'PATTERN') then
      begin
        pat := ParsePattern(lines, i);
        if pat.Id <= 0 then pat.Id := Result.FNextId;
        Result.FPatterns.Add(pat);
        if pat.Id >= Result.FNextId then Result.FNextId := pat.Id + 1;
      end
      else
        RaiseUDAWFmt(errConfig, PATTERN_SUBSYS, 'pattern parse: unexpected line "%s"', [line]);
    end;
  except
    Result.Free;
    lines.Free;
    raise;
  end;
  lines.Free;
end;

function PatternToPreset(APattern: TPattern): string;
var
  sb: TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    sb.Append(PATTERN_MAGIC).Append(' ').Append(PATTERN_VERSION).AppendLine;
    AppendPattern(sb, APattern, False);
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function PatternFromPreset(const AText: string): TPattern;
var
  lib: TPatternLibrary;
begin
  lib := PatternLibraryFromString(AText);
  try
    if lib.Count < 1 then
      RaiseUDAW(errConfig, PATTERN_SUBSYS, 'the preset holds no pattern');
    Result := lib[0].Clone;
    Result.Id := 0;
    Result.MidiClipId := 0;
  finally
    lib.Free;
  end;
end;

end.
