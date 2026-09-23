unit UDAW.Mixer.Automation;
{$I udaw.inc}

{ Mixer automation lanes: breakpoint envelopes over the Timeline's time base
  (seconds, see UDAW.Timeline.Time) that drive strip, send and insert
  parameters during playback.

  A lane identifies both a parameter kind and two integer selectors. Sends use
  TargetIndex as their destination strip id; insert parameters use TargetIndex
  as the insert slot and SubIndex as the plugin parameter index. This keeps
  automation stable when strips are reordered while still supporting dynamic
  plugin parameter sets.

  A lane is a strictly time-sorted list of breakpoints; Evaluate does linear
  interpolation between the two points bracketing a time, holds the first
  point's value before it starts and the last point's value after it ends,
  and returns zero when the lane has no points (TryEvaluate distinguishes an
  empty lane for callers). TAutomationSet owns every lane for a TMixerModel and
  is embedded in the same UDAWMIXER text document (see
  UDAW.Mixer.Serialization) - so, like TMixerModel itself, it has no GUI or
  audio-engine dependency. }

interface

uses
  SysUtils, Math, Generics.Collections;

type
  TAutomationParam = (apFader, apPan, apMute, apSendGain, apInsertParam);

  TAutomationPoint = record
    TimeSeconds: Double;
    Value: Double;
    constructor Create(ATimeSeconds, AValue: Double);
  end;

  TAutomationLane = class
  private
    FStripId: Integer;
    FParam: TAutomationParam;
    FTargetIndex: Integer;
    FSubIndex: Integer;
    FPoints: TList<TAutomationPoint>;
    function IndexAtOrAfter(ATimeSeconds: Double): Integer;
  public
    constructor Create(AStripId: Integer; AParam: TAutomationParam;
      ATargetIndex: Integer = 0; ASubIndex: Integer = 0);
    destructor Destroy; override;
    function Clone: TAutomationLane;

    function PointCount: Integer;
    function GetPoint(AIndex: Integer): TAutomationPoint;
    { Inserts, or overwrites an existing point at (nearly) the same time. }
    procedure AddPoint(ATimeSeconds, AValue: Double);
    procedure RemovePoint(AIndex: Integer);
    procedure RemoveNear(ATimeSeconds: Double; AToleranceSeconds: Double);
    procedure Clear;
    { Linear interpolation between the bracketing points; holds the nearest
      endpoint's value outside the lane's range. }
    function Evaluate(ATimeSeconds: Double): Double;

    property StripId: Integer read FStripId;
    property Param: TAutomationParam read FParam;
    property TargetIndex: Integer read FTargetIndex;
    property SubIndex: Integer read FSubIndex;
  end;

  TAutomationSet = class
  private
    FLanes: TObjectList<TAutomationLane>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    function Clone: TAutomationSet;

    function LaneCount: Integer;
    function GetLane(AIndex: Integer): TAutomationLane;
    { Returns the lane for (AStripId, AParam), creating an empty one if
      ACreate and none exists yet; nil if not ACreate and none exists. }
    function LaneFor(AStripId: Integer; AParam: TAutomationParam;
      ACreate: Boolean = False; ATargetIndex: Integer = 0;
      ASubIndex: Integer = 0): TAutomationLane;
    procedure RemoveStrip(AStripId: Integer);
    procedure RemoveTargetStrip(ATargetStripId: Integer);
    procedure RemoveSend(AStripId, ATargetStripId: Integer);
    procedure InsertInsert(AStripId, AIndex: Integer);
    procedure RemoveInsert(AStripId, AIndex: Integer);
    procedure MoveInsert(AStripId, AFromIndex, AToIndex: Integer);
    { True (and outputs the evaluated value) only when a non-empty lane exists
      for (AStripId, AParam). }
    function TryEvaluate(AStripId: Integer; AParam: TAutomationParam;
      ATimeSeconds: Double; out AValue: Double; ATargetIndex: Integer = 0;
      ASubIndex: Integer = 0): Boolean;
  end;

function AutomationParamId(AParam: TAutomationParam): string;
function AutomationParamFromId(const AId: string; out AParam: TAutomationParam): Boolean;

implementation

function AutomationParamId(AParam: TAutomationParam): string;
begin
  case AParam of
    apFader: Result := 'fader';
    apPan:   Result := 'pan';
    apMute:  Result := 'mute';
    apSendGain: Result := 'send';
    apInsertParam: Result := 'insert';
  else
    Result := '?';
  end;
end;

function AutomationParamFromId(const AId: string; out AParam: TAutomationParam): Boolean;
begin
  Result := True;
  if SameText(AId, 'fader') then AParam := apFader
  else if SameText(AId, 'pan') then AParam := apPan
  else if SameText(AId, 'mute') then AParam := apMute
  else if SameText(AId, 'send') then AParam := apSendGain
  else if SameText(AId, 'insert') then AParam := apInsertParam
  else Result := False;
end;

{ ================= TAutomationPoint ================= }

constructor TAutomationPoint.Create(ATimeSeconds, AValue: Double);
begin
  TimeSeconds := ATimeSeconds;
  Value := AValue;
end;

{ ================= TAutomationLane ================= }

constructor TAutomationLane.Create(AStripId: Integer; AParam: TAutomationParam;
  ATargetIndex, ASubIndex: Integer);
begin
  inherited Create;
  FStripId := AStripId;
  FParam := AParam;
  if ATargetIndex < 0 then ATargetIndex := 0;
  if ASubIndex < 0 then ASubIndex := 0;
  FTargetIndex := ATargetIndex;
  FSubIndex := ASubIndex;
  FPoints := TList<TAutomationPoint>.Create;
end;

destructor TAutomationLane.Destroy;
begin
  FPoints.Free;
  inherited Destroy;
end;

function TAutomationLane.Clone: TAutomationLane;
var
  i: Integer;
begin
  Result := TAutomationLane.Create(FStripId, FParam, FTargetIndex, FSubIndex);
  for i := 0 to FPoints.Count - 1 do
    Result.FPoints.Add(FPoints[i]);
end;

function TAutomationLane.PointCount: Integer;
begin
  Result := FPoints.Count;
end;

function TAutomationLane.GetPoint(AIndex: Integer): TAutomationPoint;
begin
  Result := FPoints[AIndex];
end;

function TAutomationLane.IndexAtOrAfter(ATimeSeconds: Double): Integer;
var
  i: Integer;
begin
  for i := 0 to FPoints.Count - 1 do
    if FPoints[i].TimeSeconds >= ATimeSeconds then Exit(i);
  Result := FPoints.Count;
end;

procedure TAutomationLane.AddPoint(ATimeSeconds, AValue: Double);
const
  EPS = 1.0E-4;
var
  idx: Integer;
begin
  if IsNan(ATimeSeconds) or IsInfinite(ATimeSeconds) or (ATimeSeconds < 0) then
    ATimeSeconds := 0;
  if IsNan(AValue) then AValue := 0;
  case FParam of
    apFader, apSendGain:
      begin
        if AValue < -120 then AValue := -120 else if AValue > 24 then AValue := 24;
      end;
    apPan:
      begin
        if AValue < -1 then AValue := -1 else if AValue > 1 then AValue := 1;
      end;
  else
    begin
      if AValue < 0 then AValue := 0 else if AValue > 1 then AValue := 1;
    end;
  end;
  idx := IndexAtOrAfter(ATimeSeconds - EPS);
  if (idx < FPoints.Count) and (Abs(FPoints[idx].TimeSeconds - ATimeSeconds) <= EPS) then
    FPoints[idx] := TAutomationPoint.Create(ATimeSeconds, AValue)
  else
    FPoints.Insert(idx, TAutomationPoint.Create(ATimeSeconds, AValue));
end;

procedure TAutomationLane.RemovePoint(AIndex: Integer);
begin
  if (AIndex >= 0) and (AIndex < FPoints.Count) then
    FPoints.Delete(AIndex);
end;

procedure TAutomationLane.RemoveNear(ATimeSeconds: Double; AToleranceSeconds: Double);
var
  i: Integer;
begin
  for i := FPoints.Count - 1 downto 0 do
    if Abs(FPoints[i].TimeSeconds - ATimeSeconds) <= AToleranceSeconds then
      FPoints.Delete(i);
end;

procedure TAutomationLane.Clear;
begin
  FPoints.Clear;
end;

function TAutomationLane.Evaluate(ATimeSeconds: Double): Double;
var
  idx: Integer;
  a, b: TAutomationPoint;
  frac: Double;
begin
  if FPoints.Count = 0 then Exit(0.0);
  if FPoints.Count = 1 then Exit(FPoints[0].Value);
  idx := IndexAtOrAfter(ATimeSeconds);
  if idx <= 0 then Exit(FPoints[0].Value);
  if idx >= FPoints.Count then Exit(FPoints[FPoints.Count - 1].Value);
  a := FPoints[idx - 1];
  b := FPoints[idx];
  if b.TimeSeconds <= a.TimeSeconds then Exit(b.Value);
  frac := (ATimeSeconds - a.TimeSeconds) / (b.TimeSeconds - a.TimeSeconds);
  if frac < 0 then frac := 0 else if frac > 1 then frac := 1;
  Result := a.Value + (b.Value - a.Value) * frac;
end;

{ ================= TAutomationSet ================= }

constructor TAutomationSet.Create;
begin
  inherited Create;
  FLanes := TObjectList<TAutomationLane>.Create(True);
end;

destructor TAutomationSet.Destroy;
begin
  FLanes.Free;
  inherited Destroy;
end;

procedure TAutomationSet.Clear;
begin
  FLanes.Clear;
end;

function TAutomationSet.Clone: TAutomationSet;
var
  i: Integer;
begin
  Result := TAutomationSet.Create;
  for i := 0 to FLanes.Count - 1 do
    Result.FLanes.Add(FLanes[i].Clone);
end;

function TAutomationSet.LaneCount: Integer;
begin
  Result := FLanes.Count;
end;

function TAutomationSet.GetLane(AIndex: Integer): TAutomationLane;
begin
  Result := FLanes[AIndex];
end;

function TAutomationSet.LaneFor(AStripId: Integer; AParam: TAutomationParam;
  ACreate: Boolean; ATargetIndex, ASubIndex: Integer): TAutomationLane;
var
  i: Integer;
begin
  for i := 0 to FLanes.Count - 1 do
    if (FLanes[i].StripId = AStripId) and (FLanes[i].Param = AParam) and
       (FLanes[i].TargetIndex = ATargetIndex) and
       (FLanes[i].SubIndex = ASubIndex) then
      Exit(FLanes[i]);
  Result := nil;
  if ACreate then
  begin
    Result := TAutomationLane.Create(AStripId, AParam, ATargetIndex, ASubIndex);
    FLanes.Add(Result);
  end;
end;

procedure TAutomationSet.RemoveStrip(AStripId: Integer);
var
  i: Integer;
begin
  for i := FLanes.Count - 1 downto 0 do
    if FLanes[i].StripId = AStripId then
      FLanes.Delete(i);
end;

procedure TAutomationSet.RemoveTargetStrip(ATargetStripId: Integer);
var
  i: Integer;
begin
  for i := FLanes.Count - 1 downto 0 do
    if (FLanes[i].Param = apSendGain) and
       (FLanes[i].TargetIndex = ATargetStripId) then
      FLanes.Delete(i);
end;

procedure TAutomationSet.RemoveSend(AStripId, ATargetStripId: Integer);
var
  i: Integer;
begin
  for i := FLanes.Count - 1 downto 0 do
    if (FLanes[i].StripId = AStripId) and (FLanes[i].Param = apSendGain) and
       (FLanes[i].TargetIndex = ATargetStripId) then
      FLanes.Delete(i);
end;

procedure TAutomationSet.InsertInsert(AStripId, AIndex: Integer);
var
  i: Integer;
begin
  for i := 0 to FLanes.Count - 1 do
    if (FLanes[i].StripId = AStripId) and (FLanes[i].Param = apInsertParam) and
       (FLanes[i].TargetIndex >= AIndex) then
      Inc(FLanes[i].FTargetIndex);
end;

procedure TAutomationSet.RemoveInsert(AStripId, AIndex: Integer);
var
  i: Integer;
begin
  for i := FLanes.Count - 1 downto 0 do
    if (FLanes[i].StripId = AStripId) and (FLanes[i].Param = apInsertParam) then
      if FLanes[i].TargetIndex = AIndex then
        FLanes.Delete(i)
      else if FLanes[i].TargetIndex > AIndex then
        Dec(FLanes[i].FTargetIndex);
end;

procedure TAutomationSet.MoveInsert(AStripId, AFromIndex, AToIndex: Integer);
var
  i, idx: Integer;
begin
  for i := 0 to FLanes.Count - 1 do
    if (FLanes[i].StripId = AStripId) and (FLanes[i].Param = apInsertParam) then
    begin
      idx := FLanes[i].TargetIndex;
      if idx = AFromIndex then
        FLanes[i].FTargetIndex := AToIndex
      else if (AFromIndex < AToIndex) and (idx > AFromIndex) and (idx <= AToIndex) then
        Dec(FLanes[i].FTargetIndex)
      else if (AToIndex < AFromIndex) and (idx >= AToIndex) and (idx < AFromIndex) then
        Inc(FLanes[i].FTargetIndex);
    end;
end;

function TAutomationSet.TryEvaluate(AStripId: Integer; AParam: TAutomationParam;
  ATimeSeconds: Double; out AValue: Double; ATargetIndex, ASubIndex: Integer): Boolean;
var
  lane: TAutomationLane;
begin
  AValue := 0;
  lane := LaneFor(AStripId, AParam, False, ATargetIndex, ASubIndex);
  if (lane = nil) or (lane.PointCount = 0) then Exit(False);
  AValue := lane.Evaluate(ATimeSeconds);
  Result := True;
end;

end.
