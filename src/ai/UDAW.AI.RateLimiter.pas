unit UDAW.AI.RateLimiter;
{$I udaw.inc}

{ Phase 20 - a thread-safe token-bucket rate limiter for outgoing AI provider
  calls. Two independent buckets (requests, tokens) refill continuously based
  on elapsed wall-clock time. Calls may originate on a background worker
  thread while the UI thread reads RequestsRemaining / TokensRemaining for
  display, so all state is guarded by a critical section. }

interface

uses
  SysUtils, SyncObjs, UDAW.Errors;

type
  TAIRateLimiter = class
  private
    FLock: TCriticalSection;
    FRequestsPerMinute: Integer;
    FTokensPerMinute: Integer;
    FRequestBucket: Double;    // current available requests
    FTokenBucket: Double;      // current available tokens
    FLastTick: TDateTime;
    FLastEstimatedTokens: Integer;   // estimate consumed by the most recent TryAcquire
    procedure RefillLocked;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Configure(ARequestsPerMinute, ATokensPerMinute: Integer);
    function TryAcquire(AEstimatedTokens: Integer; out AWaitMs: Integer): Boolean;
    procedure RecordActualUsage(AActualTokens: Integer);
    procedure Reset;

    function RequestsRemaining: Integer;
    function TokensRemaining: Integer;
  end;

implementation

const
  SUBSYS = 'AI.RateLimiter';
  SECONDS_PER_DAY = 86400.0;

constructor TAIRateLimiter.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FRequestsPerMinute := 60;
  FTokensPerMinute := 60000;
  FLastTick := Now;
  FLastEstimatedTokens := 0;
  Reset;
end;

destructor TAIRateLimiter.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TAIRateLimiter.Configure(ARequestsPerMinute, ATokensPerMinute: Integer);
begin
  if (ARequestsPerMinute <= 0) or (ATokensPerMinute <= 0) then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'rate limits must be positive');
  FLock.Enter;
  try
    FRequestsPerMinute := ARequestsPerMinute;
    FTokensPerMinute := ATokensPerMinute;
    FRequestBucket := ARequestsPerMinute;
    FTokenBucket := ATokensPerMinute;
    FLastTick := Now;
  finally
    FLock.Leave;
  end;
end;

{ Must be called with FLock held. Advances both buckets by the elapsed
  wall-clock time since the last check, capped at capacity. }
procedure TAIRateLimiter.RefillLocked;
var
  nowT: TDateTime;
  elapsedSec: Double;
begin
  nowT := Now;
  elapsedSec := (nowT - FLastTick) * SECONDS_PER_DAY;
  if elapsedSec < 0 then
    elapsedSec := 0;
  FLastTick := nowT;
  if elapsedSec = 0 then
    Exit;

  FRequestBucket := FRequestBucket + elapsedSec * (FRequestsPerMinute / 60.0);
  if FRequestBucket > FRequestsPerMinute then
    FRequestBucket := FRequestsPerMinute;

  FTokenBucket := FTokenBucket + elapsedSec * (FTokensPerMinute / 60.0);
  if FTokenBucket > FTokensPerMinute then
    FTokenBucket := FTokensPerMinute;
end;

function TAIRateLimiter.TryAcquire(AEstimatedTokens: Integer; out AWaitMs: Integer): Boolean;
var
  shortfallReq, shortfallTok: Double;
  waitReqSec, waitTokSec, waitSec: Double;
begin
  FLock.Enter;
  try
    RefillLocked;
    if (FRequestBucket >= 1.0) and (FTokenBucket >= AEstimatedTokens) then
    begin
      FRequestBucket := FRequestBucket - 1.0;
      FTokenBucket := FTokenBucket - AEstimatedTokens;
      FLastEstimatedTokens := AEstimatedTokens;
      AWaitMs := 0;
      Exit(True);
    end;

    shortfallReq := 1.0 - FRequestBucket;
    if shortfallReq < 0 then shortfallReq := 0;
    shortfallTok := AEstimatedTokens - FTokenBucket;
    if shortfallTok < 0 then shortfallTok := 0;

    waitReqSec := 0;
    if (shortfallReq > 0) and (FRequestsPerMinute > 0) then
      waitReqSec := shortfallReq / (FRequestsPerMinute / 60.0);
    waitTokSec := 0;
    if (shortfallTok > 0) and (FTokensPerMinute > 0) then
      waitTokSec := shortfallTok / (FTokensPerMinute / 60.0);

    waitSec := waitReqSec;
    if waitTokSec > waitSec then
      waitSec := waitTokSec;
    if waitSec <= 0 then
      waitSec := 0.001;   // still not enough this instant; suggest a minimal wait

    AWaitMs := Round(waitSec * 1000);
    if AWaitMs < 1 then
      AWaitMs := 1;
    Result := False;
  finally
    FLock.Leave;
  end;
end;

procedure TAIRateLimiter.RecordActualUsage(AActualTokens: Integer);
var
  delta: Double;
begin
  if AActualTokens < 0 then
    Exit;
  { Reconcile the token bucket against the estimate that was deducted by the
    most recent TryAcquire: if the real call used fewer tokens, credit the
    difference back; if it used more, debit the extra (the bucket may go
    negative for a short period, which simply delays the next TryAcquire -
    it never grants unlimited overdraft since RefillLocked caps at capacity,
    not below). }
  FLock.Enter;
  try
    delta := FLastEstimatedTokens - AActualTokens;
    FTokenBucket := FTokenBucket + delta;
    if FTokenBucket > FTokensPerMinute then
      FTokenBucket := FTokensPerMinute;
    FLastEstimatedTokens := AActualTokens;
  finally
    FLock.Leave;
  end;
end;

procedure TAIRateLimiter.Reset;
begin
  FLock.Enter;
  try
    FRequestBucket := FRequestsPerMinute;
    FTokenBucket := FTokensPerMinute;
    FLastTick := Now;
  finally
    FLock.Leave;
  end;
end;

function TAIRateLimiter.RequestsRemaining: Integer;
begin
  FLock.Enter;
  try
    RefillLocked;
    Result := Trunc(FRequestBucket);
  finally
    FLock.Leave;
  end;
end;

function TAIRateLimiter.TokensRemaining: Integer;
begin
  FLock.Enter;
  try
    RefillLocked;
    Result := Trunc(FTokenBucket);
  finally
    FLock.Leave;
  end;
end;

end.
