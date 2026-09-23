program UDAWUpdater;

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  Winapi.ShellAPI,
  System.SysUtils,
  System.IOUtils;

// UDAWUpdater applies a downloaded UDAW update. Launched by the
// main app (src\web\UDAW.Update.pas) immediately before it exits, never run
// standalone by a user. Windows will not let a running EXE overwrite its own
// file on disk, so this is a small separate helper that: waits for the main
// app's process to fully release its files, then copies every file from the
// already downloaded and signature-verified staging folder over this same
// folder (it ships inside the same deploy folder as UDAW.exe, so "this
// folder" - its own ExtractFilePath(ParamStr(0)) - is always the live
// install), then relaunches the main app and exits.
//
// ARGUMENTS (both required, both supplied by UDAW.Update.pas)
//   1: full path to the staging folder holding the already extracted and
//      verified update
//   2: file name only (not a path) of the main executable to wait for and
//      relaunch, e.g. UDAW.exe

const
  UDAW_UPDATER_LOCK_TIMEOUT_MS = 60000;
  UDAW_UPDATER_POLL_INTERVAL_MS = 250;
  // WinError.h value Delphi's Winapi.Windows does not declare: CreateProcess
  // fails with this when the target EXE's manifest demands elevation.
  UDAW_ERROR_ELEVATION_REQUIRED = DWORD(740);

procedure CopyDirectoryOverwrite(const ASource, ADest: string);
var
  Files: TArray<string>;
  SourceFile, RelativePath, DestFile, SelfPath, RetiredPath: string;
  Index: Integer;
begin
  SelfPath := ParamStr(0);
  ForceDirectories(ADest);
  Files := TDirectory.GetFiles(ASource, '*', TSearchOption.soAllDirectories);
  Index := 0;
  for SourceFile in Files do
  begin
    Inc(Index);
    RelativePath := SourceFile.Substring(Length(IncludeTrailingPathDelimiter(ASource)));
    Writeln(Format('Applying file %d of %d: %s', [Index, Length(Files), RelativePath]));
    DestFile := TPath.Combine(ADest, RelativePath);
    ForceDirectories(ExtractFilePath(DestFile));
    if SameFileName(DestFile, SelfPath) then
    begin
      // Windows will not let this running EXE's own file be overwritten -
      // TFile.Copy here raises a sharing violation, which would abort the
      // loop mid-update. Renaming a running EXE is allowed, so the live file
      // is retired to .old (cleaned up on the next updater run) and the new
      // one copied into its place.
      RetiredPath := DestFile + '.old';
      if TFile.Exists(RetiredPath) then
        TFile.Delete(RetiredPath);
      if not MoveFileEx(PChar(DestFile), PChar(RetiredPath),
        MOVEFILE_REPLACE_EXISTING) then
        RaiseLastOSError;
    end;
    TFile.Copy(SourceFile, DestFile, True);
  end;
end;

// Direct CreateProcess rather than ShellExecute so a failure is an error
// code that can be reported and retried instead of a silent no-op.
function LaunchProcess(const AExePath, AWorkingDir: string): Boolean;
var
  StartupInfo: TStartupInfo;
  ProcessInfo: TProcessInformation;
  CommandLine: string;
begin
  ZeroMemory(@StartupInfo, SizeOf(StartupInfo));
  StartupInfo.cb := SizeOf(StartupInfo);
  // CreateProcess may write into the command line buffer, so it must be a
  // unique writable copy, never a shared string constant.
  CommandLine := '"' + AExePath + '"';
  UniqueString(CommandLine);
  Result := CreateProcess(nil, PChar(CommandLine), nil, nil, False, 0, nil,
    PChar(AWorkingDir), StartupInfo, ProcessInfo);
  if Result then
  begin
    CloseHandle(ProcessInfo.hThread);
    CloseHandle(ProcessInfo.hProcess);
  end;
end;

// The main application must be running again before this updater ever
// closes, whatever happened - on success that is the freshly updated EXE,
// on any failure it is whatever EXE is still on disk, so the user is never
// left staring at a closed console with no UDAW running at all.
procedure RelaunchMainApplication(const AMainExePath, AWorkingDir: string);
var
  Attempt: Integer;
  ErrorCode: DWORD;
begin
  if (AMainExePath = '') or not TFile.Exists(AMainExePath) then
  begin
    Writeln('UDAW could not be restarted: its executable was not found.');
    Sleep(8000);
    Exit;
  end;
  Writeln('Restarting UDAW...');
  // A freshly copied EXE can be held briefly by antivirus scanning; retry
  // for a few seconds before giving up rather than failing on the first try.
  for Attempt := 1 to 10 do
  begin
    if LaunchProcess(AMainExePath, AWorkingDir) then
      Exit;
    ErrorCode := GetLastError;
    if ErrorCode = UDAW_ERROR_ELEVATION_REQUIRED then
    begin
      // The main application demands elevation this process does not have;
      // hand the launch to the shell, which raises the standard UAC prompt.
      if NativeInt(ShellExecute(0, 'open', PChar(AMainExePath), nil,
        PChar(AWorkingDir), SW_SHOWNORMAL)) > 32 then
        Exit;
      Writeln(Format('Restart attempt %d was refused elevation.', [Attempt]));
    end
    else
      Writeln(Format('Restart attempt %d failed: %s', [Attempt,
        SysErrorMessage(ErrorCode)]));
    Sleep(1000);
  end;
  Writeln('UDAW could not be restarted automatically. Please start it manually.');
  Sleep(10000);
end;

// Polls rather than waits on a process handle/PID - a PID can be reused by
// an unrelated process in the window between the main app exiting and this
// updater checking, whereas the file lock itself can only clear once
// Windows has actually released the mapped EXE, which is the real
// condition that matters here.
function WaitForFileUnlocked(const AFileName: string; ATimeoutMs: Cardinal): Boolean;
var
  Handle: THandle;
  Elapsed: Cardinal;
begin
  Elapsed := 0;
  repeat
    if not TFile.Exists(AFileName) then Exit(True);
    Handle := CreateFile(PChar(AFileName), GENERIC_READ or GENERIC_WRITE, 0, nil,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if Handle <> INVALID_HANDLE_VALUE then
    begin
      CloseHandle(Handle);
      Exit(True);
    end;
    Sleep(UDAW_UPDATER_POLL_INTERVAL_MS);
    Inc(Elapsed, UDAW_UPDATER_POLL_INTERVAL_MS);
  until Elapsed >= ATimeoutMs;
  Result := False;
end;

var
  StagingDir, MainExeName, TargetDir, MainExePath: string;
begin
  try
    if ParamCount < 2 then
    begin
      Writeln('UDAWUpdater requires the staging folder and main executable name as arguments.');
      Halt(1);
    end;
    StagingDir := ParamStr(1);
    MainExeName := ParamStr(2);
    TargetDir := ExtractFilePath(ParamStr(0));
    MainExePath := TargetDir + MainExeName;

    // A previous update retired the then-running updater EXE to .old (see
    // CopyDirectoryOverwrite); this run is the replacement, so the retired
    // file can go. Best effort only.
    try
      if TFile.Exists(ParamStr(0) + '.old') then
        TFile.Delete(ParamStr(0) + '.old');
    except
    end;

    Writeln('UDAW is applying an update, please wait...');

    if not WaitForFileUnlocked(MainExePath, UDAW_UPDATER_LOCK_TIMEOUT_MS) then
    begin
      Writeln('Timed out waiting for UDAW to close. Update aborted.');
      // The old install is untouched at this point - bring it back up before
      // closing.
      RelaunchMainApplication(MainExePath, TargetDir);
      Halt(2);
    end;

    CopyDirectoryOverwrite(StagingDir, TargetDir);

    try
      TDirectory.Delete(StagingDir, True);
    except
      // Best effort only - a leftover temp folder is not worth failing the
      // update over.
    end;

    RelaunchMainApplication(MainExePath, TargetDir);
  except
    on E: Exception do
    begin
      Writeln('UDAW update failed: ' + E.Message);
      RelaunchMainApplication(MainExePath, TargetDir);
      Halt(3);
    end;
  end;
end.
