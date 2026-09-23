unit UDAW.Media.Progress;
{$I udaw.inc}

{ Scoped, thread-local progress for nested media readers. Never installed on
  the real-time thread. Restoring the previous scope makes nested reads safe. }
interface
uses SysUtils, Classes;
type
  {$IFDEF FPC}
  TMediaProgressCallback = procedure(AFraction: Double; const AText: string) of object;
  {$ELSE}
  TMediaProgressCallback = reference to procedure(AFraction: Double; const AText: string);
  {$ENDIF}
  TMediaProgressScope = class
  private
    FPrevious: TMediaProgressScope;
    FCallback: TMediaProgressCallback;
    FStart, FLast: UInt64;
    FStage: string;
  public
    constructor Create(ACallback: TMediaProgressCallback);
    destructor Destroy; override;
    procedure Report(const AStage: string; ACompleted, ATotal: Int64; ASampleRate: Integer);
  end;

procedure ReportMediaProgress(const AStage: string; ACompleted, ATotal: Int64;
  ASampleRate: Integer = 0);

implementation
uses Math;
threadvar
  CurrentScope: TMediaProgressScope;

constructor TMediaProgressScope.Create(ACallback: TMediaProgressCallback);
begin
  inherited Create;
  FPrevious := CurrentScope;
  FCallback := ACallback;
  FStart := TThread.GetTickCount64;
  CurrentScope := Self;
end;

destructor TMediaProgressScope.Destroy;
begin
  CurrentScope := FPrevious;
  inherited;
end;

procedure TMediaProgressScope.Report(const AStage: string;
  ACompleted, ATotal: Int64; ASampleRate: Integer);
var
  tick: UInt64;
  fraction, elapsed: Double;
  detail: string;
begin
  if not Assigned(FCallback) then Exit;
  tick := TThread.GetTickCount64;
  if (FStage = AStage) and (tick - FLast < 250) and (ACompleted < ATotal) then Exit;
  FStage := AStage;
  FLast := tick;
  elapsed := (tick - FStart) / 1000;
  if ATotal > 0 then fraction := Min(1.0, ACompleted / ATotal) else fraction := 0;
  if ASampleRate > 0 then
    detail := Format('%s: %.1f / %.1f s decoded | %.1f s elapsed',
      [AStage, ACompleted / ASampleRate, ATotal / ASampleRate, elapsed])
  else
    detail := Format('%s: %.1f%% | %.1f s elapsed', [AStage, fraction * 100, elapsed]);
  FCallback(fraction, detail);
end;

procedure ReportMediaProgress(const AStage: string; ACompleted, ATotal: Int64;
  ASampleRate: Integer);
begin
  if CurrentScope <> nil then CurrentScope.Report(AStage, ACompleted, ATotal, ASampleRate);
end;
end.
