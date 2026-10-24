unit UDAW.CrashTrace;

{ Writes every exception that reaches the UI to the log together with the call stack it was raised
  from, as "UDAW.exe+offset" lines. A crash dialog alone says only where the fault happened, not
  how the program got there; the offsets can be looked up in a detailed map file of the same build
  (compile with -GD) to name the routines. Nothing here changes what the user sees: the usual
  error dialog is still shown. }

interface

implementation

uses
  Winapi.Windows, System.SysUtils, Vcl.Forms, UDAW.Logging;

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

procedure TCrashTrap.Handle(Sender: TObject; E: Exception);
begin
  try
    Logger.Error('ui', E.ClassName + ': ' + E.Message + sLineBreak + E.StackTrace);
  except
    // logging must never make a crash worse
  end;
  Application.ShowException(E);
end;

initialization
  Exception.GetExceptionStackInfoProc := CaptureStack;
  Exception.GetStackInfoStringProc := StackText;
  Exception.CleanUpStackInfoProc := FreeStack;
  GTrap := TCrashTrap.Create;
  Application.OnException := GTrap.Handle;

finalization
  Application.OnException := nil;
  FreeAndNil(GTrap);

end.
