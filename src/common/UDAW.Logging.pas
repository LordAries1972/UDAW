unit UDAW.Logging;
{$I udaw.inc}

{ Asynchronous, thread-safe diagnostic logger.

  Design goals (from the master plan, sections 58 and 78):
    - callers never block: entries are copied into a bounded queue and a
      background thread dispatches them to sinks; a full queue drops the
      OLDEST entry and bumps a counter rather than stalling the caller.
    - every entry carries timestamp (UTC), level, thread id, subsystem, text.
    - sinks are pluggable (console, rolling file, and - used by the UI - an
      in-memory sink the main form installs to show a live log view).

  Not yet real-time-safe from the audio callback: that path will push raw
  bytes through UDAW.Threading.TSPSCByteBuffer in Phase 2. The queue here is
  lock-based and meant for the UI / worker / IO threads. }

interface

uses
  SysUtils, Classes, Generics.Collections,
  UDAW.Threading;

type
  TLogLevel = (llTrace, llDebug, llInfo, llWarn, llError, llCritical);

  TLogEntry = record
    Time: TDateTime;   // local wall-clock time of the call
    Level: TLogLevel;
    ThreadId: TThreadID;
    Subsystem: string;
    Text: string;
    function Format: string;   // 'YYYY-MM-DD HH:NN:SS.ZZZ  LEVEL  [subsystem] (tid) text'
  end;

  ILogSink = interface
    ['{6B2C0D9E-3F4A-4C77-9A1E-1B7A2E5C9D01}']
    procedure WriteEntry(const AEntry: TLogEntry);
    procedure Flush;
    procedure Close;
    function SinkName: string;
  end;

  { --- concrete sinks --- }

  TConsoleLogSink = class(TInterfacedObject, ILogSink)
  private
    FMinLevelForStdErr: TLogLevel;
  public
    constructor Create(AMinLevelForStdErr: TLogLevel = llWarn);
    procedure WriteEntry(const AEntry: TLogEntry);
    procedure Flush;
    procedure Close;
    function SinkName: string;
  end;

  { Rolling file sink: udaw-YYYYMMDD.log in the logs directory, rolled to
    udaw-YYYYMMDD.N.log when it exceeds MaxBytes. }
  TFileLogSink = class(TInterfacedObject, ILogSink)
  private
    FDir: string;
    FMaxBytes: Int64;
    FStream: TFileStream;
    FCurrentDate: TDate;
    FCurrentPath: string;
    procedure OpenForToday;
    procedure RollIfNeeded(AAboutToWrite: Integer);
    function BuildPath(ADate: TDate; ARollIndex: Integer): string;
  public
    constructor Create(const ADir: string; AMaxBytes: Int64 = 8 * 1024 * 1024);
    destructor Destroy; override;
    procedure WriteEntry(const AEntry: TLogEntry);
    procedure Flush;
    procedure Close;
    function SinkName: string;
    property CurrentPath: string read FCurrentPath;
  end;

  { Bounded in-memory ring of the most recent entries. Thread-safe snapshot. }
  TMemoryLogSink = class(TInterfacedObject, ILogSink)
  private
    FLock: TUDAWLock;
    FItems: array of TLogEntry;
    FCount: Integer;
    FNext: Integer;
    FCapacity: Integer;
  public
    constructor Create(ACapacity: Integer = 2000);
    destructor Destroy; override;
    procedure WriteEntry(const AEntry: TLogEntry);
    procedure Flush;
    procedure Close;
    function SinkName: string;
    function Snapshot: TArray<TLogEntry>;
    procedure Clear;
  end;

  { --- logger --- }

  TLogger = class
  private
    FLock: TUDAWLock;              // guards sink list + queue
    FSinks: TList<ILogSink>;
    FQueue: TQueue<TLogEntry>;
    FSignal: TUDAWSignal;
    FWorker: TThread;
    FMinLevel: Integer;           // atomic TLogLevel
    FMaxQueue: Integer;
    FDropped: Integer;            // atomic
    FShuttingDown: Integer;       // atomic bool
    procedure Enqueue(const AEntry: TLogEntry);
    procedure DrainTo(var ABatch: TArray<TLogEntry>);
    procedure DispatchBatch(const ABatch: TArray<TLogEntry>);
    function PendingCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;

    procedure AddSink(const ASink: ILogSink);
    procedure RemoveSink(const ASink: ILogSink);
    procedure ClearSinks;

    procedure SetMinLevel(ALevel: TLogLevel);
    function MinLevel: TLogLevel;
    function DroppedCount: Integer;

    procedure Log(ALevel: TLogLevel; const ASubsystem, AText: string); overload;
    procedure LogFmt(ALevel: TLogLevel; const ASubsystem, AFmt: string;
      const AArgs: array of const);

    procedure Trace(const ASubsystem, AText: string);
    procedure Debug(const ASubsystem, AText: string);
    procedure Info(const ASubsystem, AText: string);
    procedure Warn(const ASubsystem, AText: string);
    procedure Error(const ASubsystem, AText: string);
    procedure Critical(const ASubsystem, AText: string);
    procedure LogException(const ASubsystem: string; E: Exception; const AContext: string = '');

    { Blocks (up to ATimeoutMs) until the queue is drained and sinks flushed. }
    function Flush(ATimeoutMs: Cardinal = 2000): Boolean;
  end;

function LevelName(ALevel: TLogLevel): string;

{ Process-wide logger. Created on first use with no sinks; the application
  bootstrap adds console + file sinks. }
function Logger: TLogger;
procedure ShutdownLogger;

implementation

uses
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  DateUtils;

const
  LEVEL_NAMES: array[TLogLevel] of string =
    ('TRACE', 'DEBUG', 'INFO ', 'WARN ', 'ERROR', 'CRIT ');

function LevelName(ALevel: TLogLevel): string;
begin
  Result := Trim(LEVEL_NAMES[ALevel]);
end;

{ TLogEntry }

function TLogEntry.Format: string;
begin
  Result := SysUtils.Format('%s  %s  [%s] (%u) %s',
    [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Time),
     LEVEL_NAMES[Level], Subsystem, UInt64(ThreadId), Text]);
end;

{ TConsoleLogSink }

constructor TConsoleLogSink.Create(AMinLevelForStdErr: TLogLevel);
begin
  inherited Create;
  FMinLevelForStdErr := AMinLevelForStdErr;
end;

procedure TConsoleLogSink.WriteEntry(const AEntry: TLogEntry);
var
  line: string;
begin
  if not IsConsole then
    Exit;
  line := AEntry.Format;
  if AEntry.Level >= FMinLevelForStdErr then
    Writeln(ErrOutput, line)
  else
    Writeln(Output, line);
end;

procedure TConsoleLogSink.Flush;
begin
  if not IsConsole then
    Exit;
  System.Flush(Output);
  System.Flush(ErrOutput);
end;

procedure TConsoleLogSink.Close;
begin
  Flush;
end;

function TConsoleLogSink.SinkName: string;
begin
  Result := 'console';
end;

{ TFileLogSink }

constructor TFileLogSink.Create(const ADir: string; AMaxBytes: Int64);
begin
  inherited Create;
  FDir := IncludeTrailingPathDelimiter(ADir);
  FMaxBytes := AMaxBytes;
  FCurrentDate := 0;
  OpenForToday;
end;

destructor TFileLogSink.Destroy;
begin
  Close;
  inherited Destroy;
end;

function TFileLogSink.BuildPath(ADate: TDate; ARollIndex: Integer): string;
var
  stamp: string;
begin
  stamp := FormatDateTime('yyyymmdd', ADate);
  if ARollIndex <= 0 then
    Result := FDir + 'udaw-' + stamp + '.log'
  else
    Result := FDir + Format('udaw-%s.%d.log', [stamp, ARollIndex]);
end;

procedure TFileLogSink.OpenForToday;
var
  today: TDate;
begin
  today := DateOf(Now);
  if (FStream <> nil) and (today = FCurrentDate) then
    Exit;
  FreeAndNil(FStream);
  FCurrentDate := today;
  FCurrentPath := BuildPath(today, 0);
  if not DirectoryExists(FDir) then
    ForceDirectories(FDir);
  if FileExists(FCurrentPath) then
    FStream := TFileStream.Create(FCurrentPath, fmOpenReadWrite or fmShareDenyWrite)
  else
    FStream := TFileStream.Create(FCurrentPath, fmCreate or fmShareDenyWrite);
  FStream.Seek(Int64(0), soEnd);
end;

procedure TFileLogSink.RollIfNeeded(AAboutToWrite: Integer);
var
  idx: Integer;
  target: string;
begin
  if FStream = nil then Exit;
  if FStream.Size + AAboutToWrite <= FMaxBytes then Exit;
  FreeAndNil(FStream);
  idx := 1;
  repeat
    target := BuildPath(FCurrentDate, idx);
    Inc(idx);
  until not FileExists(target);
  RenameFile(FCurrentPath, target);
  FStream := TFileStream.Create(FCurrentPath, fmCreate or fmShareDenyWrite);
end;

procedure TFileLogSink.WriteEntry(const AEntry: TLogEntry);
var
  bytes: TBytes;
  line: string;
begin
  OpenForToday;
  line := AEntry.Format + sLineBreak;
  bytes := TEncoding.UTF8.GetBytes(line);
  RollIfNeeded(Length(bytes));
  if FStream <> nil then
    FStream.WriteBuffer(bytes[0], Length(bytes));
end;

procedure TFileLogSink.Flush;
begin
  {$IFDEF MSWINDOWS}
  if FStream <> nil then
    FlushFileBuffers(FStream.Handle);
  {$ENDIF}
end;

procedure TFileLogSink.Close;
begin
  Flush;
  FreeAndNil(FStream);
end;

function TFileLogSink.SinkName: string;
begin
  Result := 'file:' + FCurrentPath;
end;

{ TMemoryLogSink }

constructor TMemoryLogSink.Create(ACapacity: Integer);
begin
  inherited Create;
  if ACapacity < 1 then ACapacity := 1;
  FCapacity := ACapacity;
  SetLength(FItems, FCapacity);
  FLock := TUDAWLock.Create('memlogsink');
end;

destructor TMemoryLogSink.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TMemoryLogSink.WriteEntry(const AEntry: TLogEntry);
begin
  FLock.Enter;
  try
    FItems[FNext] := AEntry;
    FNext := (FNext + 1) mod FCapacity;
    if FCount < FCapacity then
      Inc(FCount);
  finally
    FLock.Leave;
  end;
end;

procedure TMemoryLogSink.Flush;
begin
end;

procedure TMemoryLogSink.Close;
begin
end;

function TMemoryLogSink.SinkName: string;
begin
  Result := 'memory';
end;

function TMemoryLogSink.Snapshot: TArray<TLogEntry>;
var
  i, start: Integer;
begin
  FLock.Enter;
  try
    SetLength(Result, FCount);
    if FCount < FCapacity then
      start := 0
    else
      start := FNext;
    for i := 0 to FCount - 1 do
      Result[i] := FItems[(start + i) mod FCapacity];
  finally
    FLock.Leave;
  end;
end;

procedure TMemoryLogSink.Clear;
begin
  FLock.Enter;
  try
    FCount := 0;
    FNext := 0;
  finally
    FLock.Leave;
  end;
end;

{ TLogWorker }

type
  TLogWorker = class(TThread)
  private
    FOwner: TLogger;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TLogger);
  end;

constructor TLogWorker.Create(AOwner: TLogger);
begin
  FOwner := AOwner;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TLogWorker.Execute;
var
  batch: TArray<TLogEntry>;
begin
  {$IFDEF FPC}
  NameThreadForDebugging('udaw-log');
  {$ELSE}
  TThread.NameThreadForDebugging('udaw-log');
  {$ENDIF}
  while not Terminated do
  begin
    FOwner.FSignal.Wait(200);
    repeat
      FOwner.DrainTo(batch);
      if Length(batch) > 0 then
        FOwner.DispatchBatch(batch);
    until Length(batch) = 0;
  end;
  { final drain }
  repeat
    FOwner.DrainTo(batch);
    if Length(batch) > 0 then
      FOwner.DispatchBatch(batch);
  until Length(batch) = 0;
end;

{ TLogger }

constructor TLogger.Create;
begin
  inherited Create;
  FLock := TUDAWLock.Create('logger');
  FSinks := TList<ILogSink>.Create;
  FQueue := TQueue<TLogEntry>.Create;
  FSignal := TUDAWSignal.Create(False, False);
  FMinLevel := Ord(llInfo);
  FMaxQueue := 65536;
  FWorker := TLogWorker.Create(Self);
end;

destructor TLogger.Destroy;
var
  i: Integer;
begin
  AtomicSet32(FShuttingDown, 1);
  if FWorker <> nil then
  begin
    FWorker.Terminate;
    FSignal.Signal;
    FWorker.WaitFor;
    FreeAndNil(FWorker);
  end;
  FLock.Enter;
  try
    for i := 0 to FSinks.Count - 1 do
      FSinks[i].Close;
    FSinks.Clear;
  finally
    FLock.Leave;
  end;
  FSinks.Free;
  FQueue.Free;
  FSignal.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TLogger.AddSink(const ASink: ILogSink);
begin
  FLock.Enter;
  try
    FSinks.Add(ASink);
  finally
    FLock.Leave;
  end;
end;

procedure TLogger.RemoveSink(const ASink: ILogSink);
begin
  FLock.Enter;
  try
    FSinks.Remove(ASink);
  finally
    FLock.Leave;
  end;
end;

procedure TLogger.ClearSinks;
var
  i: Integer;
begin
  FLock.Enter;
  try
    for i := 0 to FSinks.Count - 1 do
      FSinks[i].Close;
    FSinks.Clear;
  finally
    FLock.Leave;
  end;
end;

procedure TLogger.SetMinLevel(ALevel: TLogLevel);
begin
  AtomicSet32(FMinLevel, Ord(ALevel));
end;

function TLogger.MinLevel: TLogLevel;
begin
  Result := TLogLevel(AtomicRead32(FMinLevel));
end;

function TLogger.DroppedCount: Integer;
begin
  Result := AtomicRead32(FDropped);
end;

function TLogger.PendingCount: Integer;
begin
  FLock.Enter;
  try
    Result := FQueue.Count;
  finally
    FLock.Leave;
  end;
end;

procedure TLogger.Enqueue(const AEntry: TLogEntry);
begin
  if AtomicRead32(FShuttingDown) <> 0 then
    Exit;
  FLock.Enter;
  try
    while FQueue.Count >= FMaxQueue do
    begin
      FQueue.Dequeue;
      AtomicInc32(FDropped);
    end;
    FQueue.Enqueue(AEntry);
  finally
    FLock.Leave;
  end;
  FSignal.Signal;
end;

procedure TLogger.DrainTo(var ABatch: TArray<TLogEntry>);
var
  n, i: Integer;
begin
  FLock.Enter;
  try
    n := FQueue.Count;
    if n > 512 then n := 512;
    SetLength(ABatch, n);
    for i := 0 to n - 1 do
      ABatch[i] := FQueue.Dequeue;
  finally
    FLock.Leave;
  end;
end;

procedure TLogger.DispatchBatch(const ABatch: TArray<TLogEntry>);
var
  localSinks: TArray<ILogSink>;
  i, s: Integer;
begin
  FLock.Enter;
  try
    SetLength(localSinks, FSinks.Count);
    for i := 0 to FSinks.Count - 1 do
      localSinks[i] := FSinks[i];
  finally
    FLock.Leave;
  end;

  for i := 0 to High(ABatch) do
    for s := 0 to High(localSinks) do
    try
      localSinks[s].WriteEntry(ABatch[i]);
    except
      { a failing sink must never take down the logger or the app }
    end;

  for s := 0 to High(localSinks) do
    try
      localSinks[s].Flush;
    except
    end;
end;

procedure TLogger.Log(ALevel: TLogLevel; const ASubsystem, AText: string);
var
  e: TLogEntry;
begin
  if Ord(ALevel) < AtomicRead32(FMinLevel) then
    Exit;
  e.Time := Now;
  e.Level := ALevel;
  e.ThreadId := TThread.CurrentThread.ThreadID;
  e.Subsystem := ASubsystem;
  e.Text := AText;
  Enqueue(e);
end;

procedure TLogger.LogFmt(ALevel: TLogLevel; const ASubsystem, AFmt: string;
  const AArgs: array of const);
begin
  if Ord(ALevel) < AtomicRead32(FMinLevel) then
    Exit;
  Log(ALevel, ASubsystem, SysUtils.Format(AFmt, AArgs));
end;

procedure TLogger.Trace(const ASubsystem, AText: string);
begin
  Log(llTrace, ASubsystem, AText);
end;

procedure TLogger.Debug(const ASubsystem, AText: string);
begin
  Log(llDebug, ASubsystem, AText);
end;

procedure TLogger.Info(const ASubsystem, AText: string);
begin
  Log(llInfo, ASubsystem, AText);
end;

procedure TLogger.Warn(const ASubsystem, AText: string);
begin
  Log(llWarn, ASubsystem, AText);
end;

procedure TLogger.Error(const ASubsystem, AText: string);
begin
  Log(llError, ASubsystem, AText);
end;

procedure TLogger.Critical(const ASubsystem, AText: string);
begin
  Log(llCritical, ASubsystem, AText);
end;

procedure TLogger.LogException(const ASubsystem: string; E: Exception; const AContext: string);
var
  msg: string;
begin
  if E = nil then
    Exit;
  msg := E.ClassName + ': ' + E.Message;
  if AContext <> '' then
    msg := AContext + ' -- ' + msg;
  Log(llError, ASubsystem, msg);
end;

function TLogger.Flush(ATimeoutMs: Cardinal): Boolean;
var
  deadline: TDateTime;
begin
  FSignal.Signal;
  deadline := IncMilliSecond(Now, Integer(ATimeoutMs));
  while (PendingCount > 0) and (Now < deadline) do
    Sleep(5);
  Result := PendingCount = 0;
  { give the worker a moment to finish the in-flight batch + flush sinks }
  Sleep(10);
end;

var
  GLogger: TLogger;
  GLoggerLock: TUDAWLock;

function Logger: TLogger;
begin
  if GLogger = nil then
  begin
    GLoggerLock.Enter;
    try
      if GLogger = nil then
        GLogger := TLogger.Create;
    finally
      GLoggerLock.Leave;
    end;
  end;
  Result := GLogger;
end;

procedure ShutdownLogger;
begin
  GLoggerLock.Enter;
  try
    FreeAndNil(GLogger);
  finally
    GLoggerLock.Leave;
  end;
end;

initialization
  GLoggerLock := TUDAWLock.Create('logger-singleton');

finalization
  ShutdownLogger;
  FreeAndNil(GLoggerLock);

end.
