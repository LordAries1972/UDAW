unit UDAW.Jobs;
{$I udaw.inc}

{ Background job system (plan section 52).

  A TJob is a unit of cancellable background work with observable progress.
  TJobManager runs jobs on a small fixed worker pool - never on the UI thread
  and (by design) never touching the future real-time audio thread.

  Threading contract:
    * OnProgress / OnComplete fire ON A WORKER THREAD. A GUI consumer must
      marshal to the UI thread itself (TThread.Queue / Synchronize).
    * Status(), Progress(), Note(), ErrorMessage() are safe to call from any
      thread at any time.
    * With AOwnsJob = True the manager frees the job immediately after
      OnComplete returns - read anything you need inside the handler.
      With AOwnsJob = False the caller owns the job and must keep it alive
      until it reaches a terminal status. }

interface

uses
  SysUtils, Classes, Generics.Collections,
  UDAW.Types, UDAW.Threading;

type
  TJobStatus = (jsPending, jsRunning, jsSucceeded, jsFailed, jsCancelled);

  TJob = class;
  TJobEvent = procedure(AJob: TJob) of object;

  TJob = class
  private
    FId: TUDAWId;
    FTitle: string;
    FStatus: Integer;      // atomic TJobStatus
    FCancel: Integer;      // atomic 0/1
    FLock: TUDAWLock;
    FProgress: Double;
    FNote: string;
    FError: string;
    FOnProgress: TJobEvent;
    FOnComplete: TJobEvent;
    procedure SetStatusAtomic(AStatus: TJobStatus);
  protected
    { Perform the work. Return False (or raise) to fail the job. Call
      ThrowIfCancelled / check Cancelled regularly for responsiveness. }
    function Execute: Boolean; virtual; abstract;
    procedure SetProgress(AFraction: Double; const ANote: string = '');
    function Cancelled: Boolean;
    procedure ThrowIfCancelled;
  public
    constructor Create(const ATitle: string);
    destructor Destroy; override;
    procedure Cancel;
    function Status: TJobStatus;
    function IsTerminal: Boolean;
    function Progress: Double;
    function Note: string;
    function ErrorMessage: string;
    property Id: TUDAWId read FId;
    property Title: string read FTitle;
    property OnProgress: TJobEvent read FOnProgress write FOnProgress;
    property OnComplete: TJobEvent read FOnComplete write FOnComplete;
  end;

  { A ready-made job that runs an anonymous-free procedure of object. Handy for
    tests and simple call sites. }
  TProcJobFunc = function(AJob: TJob): Boolean of object;

  TProcJob = class(TJob)
  private
    FFunc: TProcJobFunc;
  protected
    function Execute: Boolean; override;
  public
    constructor Create(const ATitle: string; AFunc: TProcJobFunc);
  end;

  TJobManager = class
  private
    FQueue: TQueue<TJob>;
    FKnown: TList<TJob>;          // pending + running
    FOwned: TList<TJob>;          // subset the manager must free
    FLock: TUDAWLock;
    FSignal: TUDAWSignal;
    FWorkers: array of TThread;
    FStop: Integer;              // atomic
    FActive: Integer;           // atomic: jobs currently in Execute
    FNextId: Int64;
    function TakeNext: TJob;
    procedure RunJob(AJob: TJob);
    function GetWorkerCount: Integer;
  public
    constructor Create(AWorkerCount: Integer = 0);
    destructor Destroy; override;

    function Submit(AJob: TJob; AOwnsJob: Boolean = True): TUDAWId;
    procedure Cancel(AId: TUDAWId);
    procedure CancelAll;
    function PendingCount: Integer;
    function ActiveCount: Integer;
    { Blocks until every queued and running job has finished, or timeout. }
    function WaitAll(ATimeoutMs: Cardinal = $FFFFFFFF): Boolean;
    property WorkerCount: Integer read GetWorkerCount;
  end;

function JobStatusName(AStatus: TJobStatus): string;

implementation

const
  STATUS_NAMES: array[TJobStatus] of string =
    ('Pending', 'Running', 'Succeeded', 'Failed', 'Cancelled');

function JobStatusName(AStatus: TJobStatus): string;
begin
  Result := STATUS_NAMES[AStatus];
end;

{ ---------------- TJob ---------------- }

constructor TJob.Create(const ATitle: string);
begin
  inherited Create;
  FTitle := ATitle;
  FLock := TUDAWLock.Create('job');
  FStatus := Ord(jsPending);
  FProgress := 0;
end;

destructor TJob.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TJob.SetStatusAtomic(AStatus: TJobStatus);
begin
  AtomicSet32(FStatus, Ord(AStatus));
end;

function TJob.Status: TJobStatus;
begin
  Result := TJobStatus(AtomicRead32(FStatus));
end;

function TJob.IsTerminal: Boolean;
begin
  Result := Status in [jsSucceeded, jsFailed, jsCancelled];
end;

procedure TJob.SetProgress(AFraction: Double; const ANote: string);
begin
  if AFraction < 0 then AFraction := 0
  else if AFraction > 1 then AFraction := 1;
  FLock.Enter;
  try
    FProgress := AFraction;
    if ANote <> '' then
      FNote := ANote;
  finally
    FLock.Leave;
  end;
  if Assigned(FOnProgress) then
    FOnProgress(Self);
end;

function TJob.Progress: Double;
begin
  FLock.Enter;
  try
    Result := FProgress;
  finally
    FLock.Leave;
  end;
end;

function TJob.Note: string;
begin
  FLock.Enter;
  try
    Result := FNote;
  finally
    FLock.Leave;
  end;
end;

function TJob.ErrorMessage: string;
begin
  FLock.Enter;
  try
    Result := FError;
  finally
    FLock.Leave;
  end;
end;

procedure TJob.Cancel;
begin
  AtomicSet32(FCancel, 1);
end;

function TJob.Cancelled: Boolean;
begin
  Result := AtomicRead32(FCancel) <> 0;
end;

procedure TJob.ThrowIfCancelled;
begin
  if Cancelled then
    raise EAbort.Create('job cancelled');
end;

{ ---------------- TProcJob ---------------- }

constructor TProcJob.Create(const ATitle: string; AFunc: TProcJobFunc);
begin
  inherited Create(ATitle);
  FFunc := AFunc;
end;

function TProcJob.Execute: Boolean;
begin
  Result := FFunc(Self);
end;

{ ---------------- worker ---------------- }

type
  TJobWorker = class(TUDAWThread)
  private
    FMgr: TJobManager;
    FIndex: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AMgr: TJobManager; AIndex: Integer);
  end;

constructor TJobWorker.Create(AMgr: TJobManager; AIndex: Integer);
begin
  FMgr := AMgr;
  FIndex := AIndex;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TJobWorker.Execute;
var
  job: TJob;
begin
  {$IFDEF FPC}
  NameThreadForDebugging('udaw-job-' + IntToStr(FIndex));
  {$ELSE}
  TThread.NameThreadForDebugging('udaw-job-' + IntToStr(FIndex));
  {$ENDIF}
  while AtomicRead32(FMgr.FStop) = 0 do
  begin
    job := FMgr.TakeNext;
    if job = nil then
    begin
      FMgr.FSignal.Wait(200);
      Continue;
    end;
    FMgr.RunJob(job);
  end;
end;

{ ---------------- TJobManager ---------------- }

constructor TJobManager.Create(AWorkerCount: Integer);
var
  i, n: Integer;
begin
  inherited Create;
  FLock := TUDAWLock.Create('jobmgr');
  FQueue := TQueue<TJob>.Create;
  FKnown := TList<TJob>.Create;
  FOwned := TList<TJob>.Create;
  FSignal := TUDAWSignal.Create(False, False);
  FNextId := 0;

  if AWorkerCount <= 0 then
  begin
    n := TThread.ProcessorCount - 1;
    if n < 2 then n := 2;
    if n > 8 then n := 8;
  end
  else
    n := AWorkerCount;

  SetLength(FWorkers, n);
  for i := 0 to n - 1 do
    FWorkers[i] := TJobWorker.Create(Self, i);
end;

destructor TJobManager.Destroy;
var
  i: Integer;
begin
  AtomicSet32(FStop, 1);
  CancelAll;
  FSignal.Signal;
  for i := 0 to High(FWorkers) do
    if FWorkers[i] <> nil then
    begin
      TJobWorker(FWorkers[i]).Terminate;
      FSignal.Signal;
      FWorkers[i].WaitFor;
      FWorkers[i].Free;
    end;

  { free everything we still own }
  for i := 0 to FOwned.Count - 1 do
    FOwned[i].Free;
  FOwned.Free;
  FKnown.Free;
  FQueue.Free;
  FSignal.Free;
  FLock.Free;
  inherited Destroy;
end;

function TJobManager.GetWorkerCount: Integer;
begin
  Result := Length(FWorkers);
end;

function TJobManager.Submit(AJob: TJob; AOwnsJob: Boolean): TUDAWId;
begin
  if AJob = nil then
    Exit(0);
  FLock.Enter;
  try
    Inc(FNextId);
    AJob.FId := FNextId;
    Result := FNextId;
    FKnown.Add(AJob);
    if AOwnsJob then
      FOwned.Add(AJob);
    FQueue.Enqueue(AJob);
  finally
    FLock.Leave;
  end;
  FSignal.Signal;
end;

function TJobManager.TakeNext: TJob;
begin
  Result := nil;
  FLock.Enter;
  try
    if FQueue.Count > 0 then
    begin
      Result := FQueue.Dequeue;
      AtomicInc32(FActive);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TJobManager.RunJob(AJob: TJob);
var
  ok: Boolean;
  owned: Boolean;
begin
  try
    if AJob.Cancelled then
      AJob.SetStatusAtomic(jsCancelled)
    else
    begin
      AJob.SetStatusAtomic(jsRunning);
      AJob.SetProgress(0);
      ok := False;
      try
        if AJob.Execute then
          ok := True;
      except
        on E: EAbort do
        begin
          AJob.FLock.Enter;
          try AJob.FError := 'cancelled'; finally AJob.FLock.Leave; end;
          ok := False;
        end;
        on E: Exception do
        begin
          AJob.FLock.Enter;
          try AJob.FError := E.ClassName + ': ' + E.Message; finally AJob.FLock.Leave; end;
          ok := False;
        end;
      end;

      if AJob.Cancelled and not ok then
        AJob.SetStatusAtomic(jsCancelled)
      else if ok then
      begin
        AJob.SetProgress(1);
        AJob.SetStatusAtomic(jsSucceeded);
      end
      else
        AJob.SetStatusAtomic(jsFailed);
    end;

    if Assigned(AJob.FOnComplete) then
      try
        AJob.FOnComplete(AJob);
      except
        { consumer callback must not crash the worker }
      end;
  finally
    FLock.Enter;
    try
      FKnown.Remove(AJob);
      owned := FOwned.Remove(AJob) >= 0;
    finally
      FLock.Leave;
    end;
    AtomicDec32(FActive);
    if owned then
      AJob.Free;
  end;
end;

procedure TJobManager.Cancel(AId: TUDAWId);
var
  i: Integer;
begin
  FLock.Enter;
  try
    for i := 0 to FKnown.Count - 1 do
      if FKnown[i].Id = AId then
      begin
        FKnown[i].Cancel;
        Break;
      end;
  finally
    FLock.Leave;
  end;
end;

procedure TJobManager.CancelAll;
var
  i: Integer;
begin
  FLock.Enter;
  try
    for i := 0 to FKnown.Count - 1 do
      FKnown[i].Cancel;
  finally
    FLock.Leave;
  end;
end;

function TJobManager.PendingCount: Integer;
begin
  FLock.Enter;
  try
    Result := FQueue.Count;
  finally
    FLock.Leave;
  end;
end;

function TJobManager.ActiveCount: Integer;
begin
  Result := AtomicRead32(FActive);
end;

function TJobManager.WaitAll(ATimeoutMs: Cardinal): Boolean;
var
  startTick: UInt64;
  elapsed: UInt64;
begin
  startTick := TThread.GetTickCount64;
  repeat
    if (PendingCount = 0) and (ActiveCount = 0) then
      Exit(True);
    Sleep(5);
    elapsed := TThread.GetTickCount64 - startTick;
  until (ATimeoutMs <> $FFFFFFFF) and (elapsed >= ATimeoutMs);
  Result := (PendingCount = 0) and (ActiveCount = 0);
end;

end.
