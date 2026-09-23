unit UDAW.Recording.Takes;
{$I udaw.inc}

{ Phase 8 - Recording: takes and comping (plan section 22 "Takes / Comping").

  A TTakeLane collects the takes produced by one recording effort - a single
  pass, or several stacked passes from loop recording / repeated punches over
  the same stretch of timeline. TTakeComp then describes which take is heard at
  each point along the lane as an ordered, gap-free list of segments; the
  default comp plays take 0 for the whole lane. SetActiveTake splits the comp at
  a boundary and assigns a take to the piece, exactly as dragging a comp edit in
  a DAW would.

  FlattenToClipSpecs turns the comp into the clip placements the timeline needs:
  one non-destructive clip per segment, each a window into its take's recorded
  .wav. Handing those specs to TCommitTakeCommand (UDAW.Recording.Commands) drops
  the comped performance onto a track as a single undoable step. }

interface

uses
  SysUtils, Math, Generics.Collections,
  UDAW.Errors,
  UDAW.Recording.Types;

type
  { One piece of the comp: [StartSeconds, StartSeconds+LengthSeconds) is played
    from take TakeIndex, reading from the take starting at TakeReadOffsetSeconds
    into that take's audio. }
  TCompSegment = record
    StartSeconds: Double;
    LengthSeconds: Double;
    TakeIndex: Integer;
    TakeReadOffsetSeconds: Double;
    function EndSeconds: Double;
  end;

  { A concrete clip placement produced by flattening a comp. }
  TRecordedClipSpec = record
    SourceWavFile: string;
    SampleRate: Integer;
    Channels: Integer;
    SourceFrameCount: Int64;
    Name: string;
    TimelineStartSeconds: Double;
    SourceOffsetSeconds: Double;
    LengthSeconds: Double;
  end;
  TRecordedClipSpecArray = array of TRecordedClipSpec;

  TTakeLane = class
  private
    FName: string;
    FTakes: TList<TRecordedTake>;
    function LaneStartSeconds: Double;
    function LaneEndSeconds: Double;
  public
    constructor Create(const AName: string = 'Comp');
    destructor Destroy; override;

    procedure AddTake(const ATake: TRecordedTake);
    function TakeCount: Integer;
    function GetTake(AIndex: Integer): TRecordedTake;

    function StartSeconds: Double;
    function LengthSeconds: Double;

    property Name: string read FName write FName;
  end;

  TTakeComp = class
  private
    FLane: TTakeLane;
    FSegments: TList<TCompSegment>;
    procedure RebuildDefault;
    function SegmentIndexAt(ASeconds: Double): Integer;
  public
    constructor Create(ALane: TTakeLane);
    destructor Destroy; override;

    { Reset to "take 0 for the whole lane". }
    procedure Reset;
    { Make [AFromSeconds, AToSeconds) play from take AWTakeIndex, splitting the
      comp at both boundaries as needed. Coordinates are lane-absolute seconds. }
    procedure SetActiveTake(AFromSeconds, AToSeconds: Double; ATakeIndex: Integer);

    function SegmentCount: Integer;
    function GetSegment(AIndex: Integer): TCompSegment;
    function ActiveTakeAt(ASeconds: Double): Integer;

    { One clip spec per comp segment, each pointing at its take's .wav. Segments
      whose take has no finalised .wav are skipped. }
    function FlattenToClipSpecs: TRecordedClipSpecArray;

    function Describe: string;
  end;

implementation

{ ================= TCompSegment ================= }

function TCompSegment.EndSeconds: Double;
begin
  Result := StartSeconds + LengthSeconds;
end;

{ ================= TTakeLane ================= }

constructor TTakeLane.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
  FTakes := TList<TRecordedTake>.Create;
end;

destructor TTakeLane.Destroy;
begin
  FTakes.Free;
  inherited Destroy;
end;

procedure TTakeLane.AddTake(const ATake: TRecordedTake);
begin
  FTakes.Add(ATake);
end;

function TTakeLane.TakeCount: Integer;
begin
  Result := FTakes.Count;
end;

function TTakeLane.GetTake(AIndex: Integer): TRecordedTake;
begin
  Result := FTakes[AIndex];
end;

function TTakeLane.LaneStartSeconds: Double;
var
  i: Integer;
begin
  if FTakes.Count = 0 then Exit(0);
  Result := FTakes[0].TimelineStartSeconds;
  for i := 1 to FTakes.Count - 1 do
    Result := Min(Result, FTakes[i].TimelineStartSeconds);
end;

function TTakeLane.LaneEndSeconds: Double;
var
  i: Integer;
  e: Double;
begin
  Result := LaneStartSeconds;
  for i := 0 to FTakes.Count - 1 do
  begin
    e := FTakes[i].TimelineStartSeconds + FTakes[i].LengthSeconds;
    if e > Result then Result := e;
  end;
end;

function TTakeLane.StartSeconds: Double;
begin
  Result := LaneStartSeconds;
end;

function TTakeLane.LengthSeconds: Double;
begin
  Result := LaneEndSeconds - LaneStartSeconds;
end;

{ ================= TTakeComp ================= }

constructor TTakeComp.Create(ALane: TTakeLane);
begin
  inherited Create;
  if ALane = nil then
    RaiseUDAW(errInvalidArgument, RECORDING_SUBSYS, 'TTakeComp: nil lane');
  FLane := ALane;
  FSegments := TList<TCompSegment>.Create;
  RebuildDefault;
end;

destructor TTakeComp.Destroy;
begin
  FSegments.Free;
  inherited Destroy;
end;

procedure TTakeComp.RebuildDefault;
var
  seg: TCompSegment;
begin
  FSegments.Clear;
  if FLane.TakeCount = 0 then Exit;
  seg.StartSeconds := FLane.StartSeconds;
  seg.LengthSeconds := FLane.LengthSeconds;
  seg.TakeIndex := 0;
  seg.TakeReadOffsetSeconds := Max(0.0,
    FLane.StartSeconds - FLane.GetTake(0).TimelineStartSeconds);
  FSegments.Add(seg);
end;

procedure TTakeComp.Reset;
begin
  RebuildDefault;
end;

function TTakeComp.SegmentIndexAt(ASeconds: Double): Integer;
var
  i: Integer;
  s: TCompSegment;
begin
  for i := 0 to FSegments.Count - 1 do
  begin
    s := FSegments[i];
    if (ASeconds >= s.StartSeconds - 1e-9) and (ASeconds < s.EndSeconds - 1e-9) then
      Exit(i);
  end;
  Result := -1;
end;

procedure TTakeComp.SetActiveTake(AFromSeconds, AToSeconds: Double; ATakeIndex: Integer);
var
  i: Integer;
  s, left, mid, right: TCompSegment;
  laneStart, laneEnd: Double;
  take: TRecordedTake;

  procedure SplitAt(ASeconds: Double);
  var
    j, idx: Integer;
    a, b: TCompSegment;
  begin
    idx := -1;
    for j := 0 to FSegments.Count - 1 do
      if (ASeconds > FSegments[j].StartSeconds + 1e-9) and
         (ASeconds < FSegments[j].EndSeconds - 1e-9) then
      begin
        idx := j;
        Break;
      end;
    if idx < 0 then Exit;
    a := FSegments[idx];
    b := a;
    a.LengthSeconds := ASeconds - a.StartSeconds;
    b.StartSeconds := ASeconds;
    b.LengthSeconds := (a.StartSeconds + FSegments[idx].LengthSeconds) - ASeconds;
    b.TakeReadOffsetSeconds := a.TakeReadOffsetSeconds + a.LengthSeconds;
    FSegments[idx] := a;
    FSegments.Insert(idx + 1, b);
  end;

begin
  if (ATakeIndex < 0) or (ATakeIndex >= FLane.TakeCount) then
    RaiseUDAWFmt(errInvalidArgument, RECORDING_SUBSYS,
      'SetActiveTake: take index %d out of range', [ATakeIndex]);
  laneStart := FLane.StartSeconds;
  laneEnd := laneStart + FLane.LengthSeconds;
  if AFromSeconds < laneStart then AFromSeconds := laneStart;
  if AToSeconds > laneEnd then AToSeconds := laneEnd;
  if AToSeconds <= AFromSeconds then Exit;

  SplitAt(AFromSeconds);
  SplitAt(AToSeconds);

  take := FLane.GetTake(ATakeIndex);
  for i := 0 to FSegments.Count - 1 do
  begin
    s := FSegments[i];
    if (s.StartSeconds >= AFromSeconds - 1e-9) and (s.EndSeconds <= AToSeconds + 1e-9) then
    begin
      s.TakeIndex := ATakeIndex;
      s.TakeReadOffsetSeconds := Max(0.0, s.StartSeconds - take.TimelineStartSeconds);
      FSegments[i] := s;
    end;
  end;

  { coalesce touching segments that now share a take }
  i := 0;
  while i < FSegments.Count - 1 do
  begin
    left := FSegments[i];
    right := FSegments[i + 1];
    if (left.TakeIndex = right.TakeIndex) and
       (Abs(left.EndSeconds - right.StartSeconds) < 1e-6) and
       (Abs((left.TakeReadOffsetSeconds + left.LengthSeconds) - right.TakeReadOffsetSeconds) < 1e-6) then
    begin
      mid := left;
      mid.LengthSeconds := left.LengthSeconds + right.LengthSeconds;
      FSegments[i] := mid;
      FSegments.Delete(i + 1);
    end
    else
      Inc(i);
  end;
end;

function TTakeComp.SegmentCount: Integer;
begin
  Result := FSegments.Count;
end;

function TTakeComp.GetSegment(AIndex: Integer): TCompSegment;
begin
  Result := FSegments[AIndex];
end;

function TTakeComp.ActiveTakeAt(ASeconds: Double): Integer;
var
  idx: Integer;
begin
  idx := SegmentIndexAt(ASeconds);
  if idx < 0 then Exit(-1);
  Result := FSegments[idx].TakeIndex;
end;

function TTakeComp.FlattenToClipSpecs: TRecordedClipSpecArray;
var
  i, n: Integer;
  s: TCompSegment;
  take: TRecordedTake;
  spec: TRecordedClipSpec;
begin
  SetLength(Result, 0);
  n := 0;
  for i := 0 to FSegments.Count - 1 do
  begin
    s := FSegments[i];
    if (s.TakeIndex < 0) or (s.TakeIndex >= FLane.TakeCount) then Continue;
    take := FLane.GetTake(s.TakeIndex);
    if take.WavFile = '' then Continue;
    if s.LengthSeconds <= 0 then Continue;

    spec.SourceWavFile := take.WavFile;
    spec.SampleRate := take.SampleRate;
    spec.Channels := take.Channels;
    spec.SourceFrameCount := take.FrameCount;
    if FSegments.Count = 1 then
      spec.Name := take.Name
    else
      spec.Name := Format('%s [%d]', [take.Name, i + 1]);
    spec.TimelineStartSeconds := s.StartSeconds;
    spec.SourceOffsetSeconds := take.SourceOffsetSeconds + s.TakeReadOffsetSeconds;
    spec.LengthSeconds := s.LengthSeconds;

    SetLength(Result, n + 1);
    Result[n] := spec;
    Inc(n);
  end;
end;

function TTakeComp.Describe: string;
var
  i: Integer;
  s: TCompSegment;
begin
  Result := Format('comp "%s": %d take(s), %d segment(s), %.3f s',
    [FLane.Name, FLane.TakeCount, FSegments.Count, FLane.LengthSeconds]);
  for i := 0 to FSegments.Count - 1 do
  begin
    s := FSegments[i];
    Result := Result + #10 + Format('  [%.3f .. %.3f]  take %d  (read @ %.3f)',
      [s.StartSeconds, s.EndSeconds, s.TakeIndex, s.TakeReadOffsetSeconds]);
  end;
end;

end.
