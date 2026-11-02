unit UDAW.CrashTrace;

{ The application's exception hook. Every exception that reaches the UI (Application.OnException) or
  escapes to the top of the program (ExceptProc) is brought here: it is written to the log with the call
  stack it was raised from (as "UDAW.exe+offset" lines - the offsets can be looked up in a detailed map
  file of the same build, compile with -GD, to name the routines), a full report is built and saved
  next to the logs, and the report is handed to the crash window (UDAW.UI.CrashForm registers itself
  with SetCrashDisplay) which shows it in a scrollable box with Copy, Save and Exit. }

interface

type
  { shows the report to the user; it does not return for an Exit }
  TCrashDisplayProc = procedure(const AReport: string; const ASavedPath: string);

procedure SetCrashDisplay(AProc: TCrashDisplayProc);

{ brings an exception to the hook by hand (for a handler that catches one and still wants the full report);
  AThreadLabel names a worker thread. The hook fires ONCE per run: the first exception arriving takes it. }
procedure ReportCrash(E: TObject; const ASource: string; const AThreadLabel: string = '');

implementation

uses
  Winapi.Windows, System.SysUtils, System.StrUtils, System.Classes, System.IOUtils, Vcl.Forms, Vcl.Dialogs,
  System.SyncObjs, UDAW.Types, UDAW.Version, UDAW.Paths, UDAW.Logging, UDAW.Threading;

const
  MAX_FRAMES = 48;

type
  PStackInfo = ^TStackInfo;
  TStackInfo = record
    Count: Integer;
    Fault: Pointer;
    Frames: array[0..MAX_FRAMES - 1] of Pointer;
  end;

  TCrashTrap = class
    procedure Handle(Sender: TObject; E: Exception);
  end;

var
  GTrap: TCrashTrap;

function RtlCaptureStackBackTrace(FramesToSkip, FramesToCapture: DWORD; BackTrace: Pointer;
  BackTraceHash: PDWORD): WORD; stdcall; external 'kernel32.dll' name 'RtlCaptureStackBackTrace';

function CaptureStack(P: PExceptionRecord): Pointer;
var
  info: PStackInfo;
begin
  New(info);
  info^.Fault := P^.ExceptionAddress;
  info^.Count := RtlCaptureStackBackTrace(1, MAX_FRAMES, @info^.Frames[0], nil);
  Result := info;
end;

function OffsetText(AAddress: Pointer): string;
var
  base: NativeUInt;
begin
  base := NativeUInt(GetModuleHandle(nil));
  if (NativeUInt(AAddress) >= base) and (NativeUInt(AAddress) < base + $4000000) then
    Result := Format('UDAW.exe+%x', [NativeUInt(AAddress) - base])
  else
    Result := Format('%p', [AAddress]);
end;

function StackText(AInfo: Pointer): string;
var
  info: PStackInfo;
  i: Integer;
begin
  info := PStackInfo(AInfo);
  Result := 'at ' + OffsetText(info^.Fault);
  for i := 0 to info^.Count - 1 do
    Result := Result + sLineBreak + '    ' + OffsetText(info^.Frames[i]);
end;

procedure FreeStack(AInfo: Pointer);
begin
  Dispose(PStackInfo(AInfo));
end;

var
  GDisplay: TCrashDisplayProc;
  GFired: Integer;         // 1 once the first exception has been taken: the hook fires ONCE per run
  GPresented: Integer;     // 1 once something is on screen (the crash window or the plain fallback box)

procedure SetCrashDisplay(AProc: TCrashDisplayProc);
begin
  GDisplay := AProc;
end;

{ names the thread the report is about: the caller's label for a worker, "main (UI)" for the main one }
function ThreadText(const AThreadLabel: string): string;
begin
  if GetCurrentThreadId = MainThreadID then
    Result := Format('main (UI) thread, id %d', [GetCurrentThreadId])
  else if AThreadLabel <> '' then
    Result := Format('"%s" worker thread, id %d', [AThreadLabel, GetCurrentThreadId])
  else
    Result := Format('unnamed worker thread, id %d', [GetCurrentThreadId]);
end;

function BuildReport(E: TObject; const ASource, AThreadLabel: string): string;
var
  sb: TStringBuilder;
  ex: Exception;
  depth: Integer;
begin
  sb := TStringBuilder.Create;
  try
    sb.AppendLine('UDAW crash report');
    sb.AppendLine('=================');
    sb.AppendLine('Time:      ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    sb.AppendLine('Version:   ' + UDAWDisplayVersionString);
    sb.AppendLine('System:    ' + TOSVersion.ToString);
    sb.AppendLine('Program:   ' + ParamStr(0));
    sb.AppendLine('Thread:    ' + ThreadText(AThreadLabel));
    sb.AppendLine('Caught by: ' + ASource);
    sb.AppendLine;
    if E is Exception then
    begin
      ex := Exception(E);
      depth := 0;
      while ex <> nil do
      begin
        if depth = 0 then sb.AppendLine('Exception: ' + ex.ClassName)
        else sb.AppendLine('Caused by: ' + ex.ClassName);
        sb.AppendLine('Message:   ' + ex.Message);
        sb.AppendLine('Trace:');
        if ex.StackTrace <> '' then sb.AppendLine('  ' + StringReplace(ex.StackTrace, sLineBreak, sLineBreak + '  ', [rfReplaceAll]))
        else sb.AppendLine('  (no stack information)');
        sb.AppendLine;
        ex := ex.InnerException;
        Inc(depth);
      end;
    end
    else if E <> nil then
      sb.AppendLine('Exception object: ' + E.ClassName)
    else
      sb.AppendLine('Exception object: (none)');
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

{ puts the report on screen - whichever thread gets here first wins, the other does nothing }
procedure Present(const AReport, APath: string; AFallbackOnly: Boolean);
begin
  if TInterlocked.CompareExchange(GPresented, 1, 0) <> 0 then Exit;
  try
    if Assigned(GDisplay) and not AFallbackOnly then
      GDisplay(AReport, APath)   // does not return
    else
      MessageBox(0, PChar(AReport), 'UDAW - unexpected error', MB_OK or MB_ICONSTOP or MB_TOPMOST);
  except
    on X: Exception do
      MessageBox(0, PChar(AReport + sLineBreak + sLineBreak + '(crash window failed: ' + X.Message + ')'),
        'UDAW - unexpected error', MB_OK or MB_ICONSTOP or MB_TOPMOST);
  end;
  ExitProcess(1);
end;

{ The one entry point. FIRST CAUGHT, ONCE ONLY: the first exception to arrive - from the main thread
  or from any worker - is logged, written to a report file and shown; every later one is only
  logged, because after the first error nothing more is trustworthy and a second window would just
  bury the first. A worker thread cannot touch the UI itself, so it queues the window onto the main
  thread; if the main thread does not take it within a few seconds (it is stuck), the worker shows a
  plain Windows box instead. }
procedure ReportCrash(E: TObject; const ASource: string; const AThreadLabel: string);
var
  report, path: string;
  waited: Integer;
  showProc: TThreadProcedure;
begin
  if E is EAbort then Exit;   // a deliberate silent abort is not a crash
  try
    if E is Exception then
      Logger.Error('ui', '[' + ThreadText(AThreadLabel) + '] ' + Exception(E).ClassName + ': ' +
        Exception(E).Message + sLineBreak + Exception(E).StackTrace);
  except
    // logging must never make a crash worse
  end;
  if TInterlocked.CompareExchange(GFired, 1, 0) <> 0 then Exit;   // not the first: logged above, nothing more

  report := '';
  path := '';
  try
    report := BuildReport(E, ASource, AThreadLabel);
    path := LogFile('crash-' + FormatDateTime('yyyymmdd-hhnnss', Now) + '.txt');
    try
      ForceDirectories(ExtractFilePath(path));
      TFile.WriteAllText(path, report, TEncoding.UTF8);
    except
      path := '';   // the window still shows everything; Save lets the user keep it
    end;
    if GetCurrentThreadId = MainThreadID then
      Present(report, path, False)
    else
    begin
      showProc :=
        procedure
        begin
          Present(report, path, False);
        end;
      TThread.Queue(nil, showProc);
      waited := 0;
      while (TInterlocked.CompareExchange(GPresented, 0, 0) = 0) and (waited < 4000) do
      begin
        Sleep(20);
        Inc(waited, 20);
      end;
      if TInterlocked.CompareExchange(GPresented, 0, 0) = 0 then Present(report, path, True);   // main thread is not pumping: plain box
    end;
  except
    on X: Exception do
      try
        MessageBox(0, PChar(report + sLineBreak + sLineBreak + '(crash hook failed: ' + X.Message + ')'),
          'UDAW - unexpected error', MB_OK or MB_ICONSTOP or MB_TOPMOST);
        ExitProcess(1);
      except
      end;
  end;
end;

{ the exception hook for worker threads (UDAW.Threading.UDAWThreadCrashHook) }
procedure ThreadCrash(E: TObject; const AThreadLabel: string);
begin
  ReportCrash(E, 'worker thread', AThreadLabel);
end;

procedure TCrashTrap.Handle(Sender: TObject; E: Exception);
begin
  ReportCrash(E, 'Application.OnException', '');
end;

{ an exception that escaped everything, including start-up and shut-down code outside the message loop }
procedure UnhandledException(ExceptObject: TObject; ExceptAddr: Pointer);
begin
  ReportCrash(ExceptObject, 'ExceptProc (unhandled at ' + OffsetText(ExceptAddr) + ')', '');
end;

initialization
  Exception.GetExceptionStackInfoProc := CaptureStack;
  Exception.GetStackInfoStringProc := StackText;
  Exception.CleanUpStackInfoProc := FreeStack;
  GTrap := TCrashTrap.Create;
  Application.OnException := GTrap.Handle;
  ExceptProc := @UnhandledException;
  UDAWThreadCrashHook := ThreadCrash;

finalization
  UDAWThreadCrashHook := nil;
  Application.OnException := nil;
  FreeAndNil(GTrap);

end.
