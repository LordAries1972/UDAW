unit Tests.Phase1;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}

{ Phase 1 acceptance tests: platform, paths, threading primitives, errors,
  configuration persistence, the async logger, the job manager and secure
  storage. Register them with RegisterPhase1Tests, then call RunRegisteredTests.

  Requires src/common on the compiler's unit + include search path. }

interface

procedure RegisterPhase1Tests;

implementation

uses
  SysUtils, Classes,
  UDAW.Testing,
  UDAW.Types, UDAW.Platform, UDAW.Paths, UDAW.Threading, UDAW.Errors,
  UDAW.Config, UDAW.Logging, UDAW.Jobs, UDAW.SecureStorage;

{ ---------------- helpers ---------------- }

function GetTempDirSafe: string;
begin
  {$IFDEF FPC}
  Result := GetTempDir;
  {$ELSE}
  Result := GetEnvironmentVariable('TEMP');
  if Result = '' then
    Result := GetCurrentDir;
  {$ENDIF}
end;

function ScratchDir: string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDirSafe) + 'udaw-tests' + PathDelim +
    FormatDateTime('yyyymmdd-hhnnsszzz', Now) + '-' + IntToStr(Random(100000)) + PathDelim;
  ForceDirectories(Result);
end;

type
  TOwnFreeHelper = class
  public
    RanFlag: PBoolean;
    function Body(AJob: TJob): Boolean;
  end;

function TOwnFreeHelper.Body(AJob: TJob): Boolean;
begin
  RanFlag^ := True;
  Result := True;
end;

{ ---------------- types / version ---------------- }

procedure Test_Version;
begin
  CheckEqualStr('1.0.0', UDAWVersionString, 'semantic version');
  CheckEqualStr(UDAW_SHORT_NAME + ' ' + UDAWVersionString, UDAWFullVersionString, 'full version string');
end;

procedure Test_Result;
var
  r: TUDAWResult;
begin
  r := TUDAWResult.Ok;
  CheckEqualBool(True, r.Success, 'Ok.Success');
  r := TUDAWResult.Fail(7, 'boom');
  CheckEqualBool(False, r.Success, 'Fail.Success');
  CheckEqualInt(7, r.Code, 'Fail.Code');
  CheckEqualStr('boom', r.Message, 'Fail.Message');
end;

{ ---------------- platform ---------------- }

procedure Test_Platform;
var
  p: TPlatformInfo;
begin
  p := CurrentPlatform;
  Check(p.OS <> osUnknown, 'OS detected');
  Check(p.Arch <> archUnknown, 'architecture detected');
  Check(p.LogicalCPUCount >= 1, 'at least one CPU');
  Check(Length(p.OSName) > 0, 'OS name non-empty');
  Check(Length(p.Summary) > 0, 'summary non-empty');
  {$IFDEF MSWINDOWS}
  CheckEqualBool(True, p.OS = osWindows, 'Windows build reports osWindows');
  {$ENDIF}
end;

{ ---------------- paths ---------------- }

procedure Test_Paths;
var
  pp: TUDAWPaths;
begin
  EnsureDirs;
  pp := Paths;
  Check(DirectoryExists(pp.Config), 'config dir exists after EnsureDirs');
  Check(DirectoryExists(pp.Logs), 'logs dir exists after EnsureDirs');
  Check(DirectoryExists(pp.Cache), 'cache dir exists after EnsureDirs');
  CheckEqualStr(IncludeTrailingPathDelimiter(pp.Config), pp.Config, 'config has trailing sep');
  Check(Pos(UDAW_SHORT_NAME, pp.Config) > 0, 'config path contains product short name');
  Check(ConfigFile('x.ini') = pp.Config + 'x.ini', 'ConfigFile join');
end;

{ ---------------- threading: atomics ---------------- }

procedure Test_Atomics;
var
  v: Integer;
begin
  v := 0;
  CheckEqualInt(1, AtomicInc32(v), 'inc returns new value');
  CheckEqualInt(1, AtomicRead32(v), 'read after inc');
  CheckEqualInt(0, AtomicDec32(v), 'dec returns new value');
  CheckEqualInt(0, AtomicSet32(v, 42), 'set returns previous');
  CheckEqualInt(42, AtomicRead32(v), 'read after set');
  CheckEqualBool(True, AtomicCAS32(v, 43, 42), 'CAS succeeds on match');
  CheckEqualBool(False, AtomicCAS32(v, 99, 42), 'CAS fails on mismatch');
  CheckEqualInt(43, AtomicRead32(v), 'value after CAS');
end;

type
  TAtomicStress = class(TThread)
  public
    Counter: PInteger;
    Iterations: Integer;
    procedure Execute; override;
  end;

procedure TAtomicStress.Execute;
var
  i: Integer;
begin
  for i := 1 to Iterations do
    AtomicInc32(Counter^);
end;

procedure Test_Atomics_Concurrent;
const
  ITER = 50000;
var
  shared: Integer;
  threads: array[0..3] of TAtomicStress;
  i: Integer;
begin
  shared := 0;
  for i := 0 to High(threads) do
  begin
    threads[i] := TAtomicStress.Create(True);
    threads[i].FreeOnTerminate := False;
    threads[i].Counter := @shared;
    threads[i].Iterations := ITER;
  end;
  for i := 0 to High(threads) do threads[i].Start;
  for i := 0 to High(threads) do
  begin
    threads[i].WaitFor;
    threads[i].Free;
  end;
  CheckEqualInt(Int64(Length(threads)) * ITER, shared, 'no lost increments under contention');
end;

{ ---------------- threading: lock ---------------- }

procedure Test_Lock;
var
  lk: TUDAWLock;
begin
  lk := TUDAWLock.Create('t');
  try
    lk.Enter;
    try
      Check(lk.TryEnter, 'recursive TryEnter succeeds');
      lk.Leave;
    finally
      lk.Leave;
    end;
  finally
    lk.Free;
  end;
end;

{ ---------------- threading: SPSC ring buffer ---------------- }

procedure Test_RingBuffer_Basic;
var
  rb: TSPSCByteBuffer;
  src, dst: TBytes;
  n: Cardinal;
  i: Integer;
begin
  rb := TSPSCByteBuffer.Create(100);      // rounds to 128
  try
    CheckEqualInt(128, rb.Capacity, 'capacity rounded to power of two');
    CheckEqualInt(0, rb.BytesAvailable, 'starts empty');
    CheckEqualInt(128, rb.BytesFree, 'starts fully free');

    SetLength(src, 50);
    for i := 0 to 49 do src[i] := Byte(i + 1);
    CheckEqualInt(50, rb.Write(src[0], 50), 'wrote 50');
    CheckEqualInt(50, rb.BytesAvailable, '50 available');

    SetLength(dst, 50);
    n := rb.Read(dst[0], 50);
    CheckEqualInt(50, n, 'read 50');
    for i := 0 to 49 do
      CheckEqualInt(i + 1, dst[i], 'byte roundtrip @' + IntToStr(i));
    CheckEqualInt(0, rb.BytesAvailable, 'empty again');
  finally
    rb.Free;
  end;
end;

procedure Test_RingBuffer_Overfill;
var
  rb: TSPSCByteBuffer;
  src: TBytes;
begin
  rb := TSPSCByteBuffer.Create(16);
  try
    SetLength(src, 100);
    CheckEqualInt(16, rb.Write(src[0], 100), 'write is clamped to free space');
    CheckEqualInt(0, rb.Write(src[0], 1), 'no room left');
  finally
    rb.Free;
  end;
end;

type
  TRingProducer = class(TThread)
  public
    Buf: TSPSCByteBuffer;
    Total: Integer;
    procedure Execute; override;
  end;

procedure TRingProducer.Execute;
var
  sent: Integer;
  b: Byte;
begin
  sent := 0;
  while sent < Total do
  begin
    b := Byte(sent and $FF);
    if Buf.Write(b, 1) = 1 then
      Inc(sent)
    else
      TThread.Yield;
  end;
end;

procedure Test_RingBuffer_Threaded;
const
  N = 200000;
var
  rb: TSPSCByteBuffer;
  prod: TRingProducer;
  got, expected: Integer;
  b: Byte;
begin
  rb := TSPSCByteBuffer.Create(1024);
  prod := TRingProducer.Create(True);
  prod.FreeOnTerminate := False;
  prod.Buf := rb;
  prod.Total := N;
  try
    prod.Start;
    got := 0;
    while got < N do
    begin
      if rb.Read(b, 1) = 1 then
      begin
        expected := got and $FF;
        CheckEqualInt(expected, b, 'ordered byte stream @' + IntToStr(got));
        Inc(got);
      end
      else
        TThread.Yield;
    end;
    prod.WaitFor;
    CheckEqualInt(N, got, 'consumed everything the producer sent');
  finally
    prod.Free;
    rb.Free;
  end;
end;

{ ---------------- errors ---------------- }

procedure Test_Errors;
var
  raised: Boolean;
begin
  CheckEqualStr('SecureStorage', ErrorCodeName(errSecureStorage), 'code name');
  raised := False;
  try
    RaiseUDAWFmt(errConfig, 'X', 'bad %d', [3]);
  except
    on E: EUDAWError do
    begin
      raised := True;
      CheckEqualBool(True, E.Code = errConfig, 'code preserved');
      CheckEqualStr('X', E.Subsystem, 'subsystem preserved');
      CheckEqualStr('bad 3', E.Message, 'formatted message');
    end;
  end;
  Check(raised, 'EUDAWError was raised');
end;

{ ---------------- config ---------------- }

procedure Test_Config_Roundtrip;
var
  dir, path: string;
  c: TConfig;
begin
  dir := ScratchDir;
  path := dir + 'cfg.ini';
  c := TConfig.Create(path);
  try
    c.SetString('s', 'name', 'hello world');
    c.SetInt('s', 'count', 123);
    c.SetBool('s', 'flag', True);
    c.SetFloat('s', 'ratio', 1.5);
    Check(c.Save, 'save ok');
    Check(FileExists(path), 'ini file written');
  finally
    c.Free;
  end;

  c := TConfig.Create(path);
  try
    CheckEqualStr('hello world', c.GetString('s', 'name', ''), 'string persisted');
    CheckEqualInt(123, c.GetInt('s', 'count', 0), 'int persisted');
    CheckEqualBool(True, c.GetBool('s', 'flag', False), 'bool persisted');
    CheckNear(1.5, c.GetFloat('s', 'ratio', 0), 0.0001, 'float persisted (invariant)');
    CheckEqualInt(0, c.GetInt('s', 'missing', 0), 'default for missing key');
  finally
    c.Free;
  end;
end;

procedure Test_Config_AtomicSaveKeepsBackup;
var
  dir, path: string;
  c: TConfig;
begin
  dir := ScratchDir;
  path := dir + 'cfg.ini';
  c := TConfig.Create(path);
  try
    c.SetString('s', 'v', 'first');
    c.Save;
    c.SetString('s', 'v', 'second');
    c.Save;
  finally
    c.Free;
  end;
  Check(FileExists(path), 'live config present');
  Check(FileExists(path + '.bak'), 'previous version kept as .bak');
  Check(not FileExists(path + '.tmp'), 'no leftover temp file');
end;

{ ---------------- logging ---------------- }

type
  TCountingSink = class(TInterfacedObject, ILogSink)
  public
    Count: Integer;
    Last: string;
    procedure WriteEntry(const AEntry: TLogEntry);
    procedure Flush;
    procedure Close;
    function SinkName: string;
  end;

procedure TCountingSink.WriteEntry(const AEntry: TLogEntry);
begin
  AtomicInc32(Count);
  Last := AEntry.Text;
end;

procedure TCountingSink.Flush; begin end;
procedure TCountingSink.Close; begin end;
function TCountingSink.SinkName: string; begin Result := 'counting'; end;

procedure Test_Logger_DispatchAndLevel;
var
  lg: TLogger;
  sink: TCountingSink;
  isink: ILogSink;
begin
  lg := TLogger.Create;
  try
    sink := TCountingSink.Create;
    isink := sink;
    lg.AddSink(isink);
    lg.SetMinLevel(llInfo);

    lg.Debug('t', 'below threshold - dropped');
    lg.Info('t', 'one');
    lg.Warn('t', 'two');
    lg.Flush(2000);

    CheckEqualInt(2, sink.Count, 'debug filtered, info+warn delivered');
    CheckEqualStr('two', sink.Last, 'last entry text');

    lg.SetMinLevel(llError);
    lg.Warn('t', 'now filtered');
    lg.Flush(2000);
    CheckEqualInt(2, sink.Count, 'raising level filters subsequent entries');
  finally
    lg.Free;
  end;
end;

procedure Test_Logger_MemorySink;
var
  lg: TLogger;
  mem: TMemoryLogSink;
  snap: TArray<TLogEntry>;
  i: Integer;
begin
  lg := TLogger.Create;
  try
    mem := TMemoryLogSink.Create(8);
    lg.AddSink(mem);
    lg.SetMinLevel(llTrace);
    for i := 1 to 20 do
      lg.Info('t', 'entry ' + IntToStr(i));
    lg.Flush(2000);
    snap := mem.Snapshot;
    CheckEqualInt(8, Length(snap), 'memory sink keeps only its capacity');
    CheckEqualStr('entry 13', snap[0].Text, 'oldest retained entry');
    CheckEqualStr('entry 20', snap[High(snap)].Text, 'newest entry');
    mem.Clear;
    CheckEqualInt(0, Length(mem.Snapshot), 'clear empties the sink');
  finally
    lg.Free;
  end;
end;

procedure Test_Logger_FileSink;
var
  lg: TLogger;
  dir: string;
  fs: TFileLogSink;
  txt: TStringList;
  strm: TFileStream;
begin
  dir := ScratchDir;
  lg := TLogger.Create;
  try
    fs := TFileLogSink.Create(dir, 1024 * 1024);
    lg.AddSink(fs);
    lg.SetMinLevel(llInfo);
    lg.Error('disk', 'persisted line');
    lg.Flush(2000);
    Check(FileExists(fs.CurrentPath), 'log file created');
    txt := TStringList.Create;
    try
      { the sink keeps the file open (deny-write); read it with a shared handle }
      strm := TFileStream.Create(fs.CurrentPath, fmOpenRead or fmShareDenyNone);
      try
        txt.LoadFromStream(strm);
      finally
        strm.Free;
      end;
      Check(Pos('persisted line', txt.Text) > 0, 'entry written to file');
      Check(Pos('[disk]', txt.Text) > 0, 'subsystem written to file');
    finally
      txt.Free;
    end;
  finally
    lg.Free;
  end;
end;

{ ---------------- jobs ---------------- }

type
  TCountingJob = class(TJob)
  public
    Steps: Integer;
    Ran: Boolean;
    ShouldFail: Boolean;
  protected
    function Execute: Boolean; override;
  end;

function TCountingJob.Execute: Boolean;
var
  i: Integer;
begin
  Ran := True;
  for i := 1 to Steps do
  begin
    ThrowIfCancelled;
    SetProgress(i / Steps, 'step ' + IntToStr(i));
    Sleep(2);
  end;
  if ShouldFail then
    raise Exception.Create('deliberate failure');
  Result := True;
end;

procedure Test_Job_Success;
var
  mgr: TJobManager;
  job: TCountingJob;
begin
  mgr := TJobManager.Create(2);
  job := TCountingJob.Create('ok job');
  job.Steps := 10;
  try
    mgr.Submit(job, False);
    Check(mgr.WaitAll(5000), 'WaitAll returns before timeout');
    CheckEqualBool(True, job.Ran, 'job executed');
    CheckEqualBool(True, job.Status = jsSucceeded, 'status succeeded');
    CheckNear(1.0, job.Progress, 0.0001, 'progress reaches 1.0');
  finally
    job.Free;
    mgr.Free;
  end;
end;

procedure Test_Job_Failure;
var
  mgr: TJobManager;
  job: TCountingJob;
begin
  mgr := TJobManager.Create(2);
  job := TCountingJob.Create('bad job');
  job.Steps := 3;
  job.ShouldFail := True;
  try
    mgr.Submit(job, False);
    mgr.WaitAll(5000);
    CheckEqualBool(True, job.Status = jsFailed, 'status failed');
    Check(Pos('deliberate failure', job.ErrorMessage) > 0, 'error message captured');
  finally
    job.Free;
    mgr.Free;
  end;
end;

procedure Test_Job_Cancel;
var
  mgr: TJobManager;
  job: TCountingJob;
  id: TUDAWId;
begin
  mgr := TJobManager.Create(2);
  job := TCountingJob.Create('long job');
  job.Steps := 500;   // ~1s of work
  try
    id := mgr.Submit(job, False);
    Sleep(40);
    mgr.Cancel(id);
    Check(mgr.WaitAll(5000), 'cancelled job finishes quickly');
    CheckEqualBool(True, job.Status = jsCancelled, 'status cancelled');
    Check(job.Progress < 1.0, 'cancelled before completion');
  finally
    job.Free;
    mgr.Free;
  end;
end;

procedure Test_Job_ManagerOwnsAndFrees;
var
  mgr: TJobManager;
  ran: Boolean;
  helper: TOwnFreeHelper;
begin
  ran := False;
  helper := TOwnFreeHelper.Create;
  helper.RanFlag := @ran;
  mgr := TJobManager.Create(2);
  try
    mgr.Submit(TProcJob.Create('owned', helper.Body), True);
    Check(mgr.WaitAll(5000), 'owned job completes');
    Sleep(30);
    CheckEqualBool(True, ran, 'owned job body ran and manager freed it without crashing');
  finally
    mgr.Free;
    helper.Free;
  end;
end;

{ ---------------- secure storage ---------------- }

procedure Test_SecureStorage;
const
  KEY = 'udaw.selftest.key';
var
  store: ISecureStore;
  v: string;
  ok: Boolean;
begin
  store := SecureStore;
  Check(Length(store.ProviderName) > 0, 'provider named');
  if not store.IsAvailable then
  begin
    Writeln('       (secure storage provider not available on this host - roundtrip skipped)');
    Exit;
  end;
  store.SetSecret(KEY, 'p@ss w0rd with spaces');
  try
    ok := store.GetSecret(KEY, v);
    CheckEqualBool(True, ok, 'secret retrieved');
    CheckEqualStr('p@ss w0rd with spaces', v, 'secret roundtrips exactly');
    CheckEqualBool(True, store.HasSecret(KEY), 'HasSecret true');
  finally
    store.DeleteSecret(KEY);
  end;
  CheckEqualBool(False, store.GetSecret(KEY, v), 'secret gone after delete');
end;

{ ---------------- registration ---------------- }

procedure RegisterPhase1Tests;
begin
  RegisterTest('types',      'version string',            @Test_Version);
  RegisterTest('types',      'result record',             @Test_Result);

  RegisterTest('platform',   'detection',                 @Test_Platform);

  RegisterTest('paths',      'standard directories',      @Test_Paths);

  RegisterTest('threading',  'atomics (single thread)',   @Test_Atomics);
  RegisterTest('threading',  'atomics (contended)',       @Test_Atomics_Concurrent);
  RegisterTest('threading',  'recursive lock',            @Test_Lock);
  RegisterTest('threading',  'ring buffer basic',         @Test_RingBuffer_Basic);
  RegisterTest('threading',  'ring buffer overfill',      @Test_RingBuffer_Overfill);
  RegisterTest('threading',  'ring buffer SPSC threaded', @Test_RingBuffer_Threaded);

  RegisterTest('errors',     'EUDAWError carries code',   @Test_Errors);

  RegisterTest('config',     'value roundtrip',           @Test_Config_Roundtrip);
  RegisterTest('config',     'atomic save keeps backup',  @Test_Config_AtomicSaveKeepsBackup);

  RegisterTest('logging',    'dispatch + level filter',   @Test_Logger_DispatchAndLevel);
  RegisterTest('logging',    'memory ring sink',          @Test_Logger_MemorySink);
  RegisterTest('logging',    'rolling file sink',         @Test_Logger_FileSink);

  RegisterTest('jobs',       'success + progress',        @Test_Job_Success);
  RegisterTest('jobs',       'failure captured',          @Test_Job_Failure);
  RegisterTest('jobs',       'cooperative cancel',        @Test_Job_Cancel);
  RegisterTest('jobs',       'manager owns and frees',    @Test_Job_ManagerOwnsAndFrees);

  RegisterTest('secure',     'secret roundtrip',          @Test_SecureStorage);
end;

end.
