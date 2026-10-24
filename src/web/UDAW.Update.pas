unit UDAW.Update;

{ Online version/checksum check and self-update for UDAW, ported from the
  CyberRealm/Phoenix clients (same server-side mechanism).

  VERSION + CHECKSUM CHECK: a plain GET of a static, HMAC-SHA256-signed JSON
  manifest, https://ultimanium.com/udaw-version-win64.json, with fields
  platform, version, generated, package, sha256 (of the update ZIP),
  exe_sha256 (of the UDAW.exe inside it) and sig, where
    sig = HMAC-SHA256(version|platform|package|sha256|exe_sha256,
                      UDAW_SYSTEM_ACCESS_KEY).
  Any fetch/parse/signature failure is a failure of the check itself - there is
  no "assume up to date" fallback (callers treat it as "no verdict").

  ANTI-PIRACY CHECKSUM: when the server's version equals the running build's
  version, the running EXE's own SHA-256 must equal the manifest's exe_sha256.
  A mismatch means a modified/cracked binary: in RELEASE builds it sets
  TUDAWLicense.TamperDetected, which forces the unregistered edition for the
  run regardless of any licence check. (Debug builds never trip this - a local
  compile can legitimately differ from the published build.)

  APPLYING AN UPDATE: Windows will not let a running EXE overwrite itself, so
  this unit downloads and SHA-256-verifies the ZIP (against the already
  signature-checked manifest value), extracts it to a private temp staging
  folder, launches UDAWUpdater.exe (shipped beside UDAW.exe) with that folder and
  the main EXE's file name, and the caller must exit immediately - the updater
  waits for the file lock to clear, copies the staged files over the install
  and relaunches UDAW. }

interface

type
  TUDAWUpdateInfo = record
    ServerVersion: string;
    CurrentVersion: string;
    UpdateAvailable: Boolean;
    { Same-version build whose EXE hash differs from the signed manifest. }
    ExeMismatch: Boolean;
    { Same-version build where any file listed in the signed manifest is
      missing or differs. }
    FilesMismatch: Boolean;
  end;

  TUDAWUpdateProgress = reference to procedure(const ADetail: string; APosition, ATotal: Integer);

{ Downloads and HMAC-verifies the manifest. Returns False on ANY failure to
  complete the check itself. AInfo is only meaningful when this returns True.
  Blocking network I/O - never call from the UI thread except via the
  bounded variant below. }
function UDAWCheckForUpdate(out AInfo: TUDAWUpdateInfo; out AErrorMessage: string): Boolean;

{ Downloads/verifies/stages the package from the last successful
  UDAWCheckForUpdate and launches UDAWUpdater.exe. True only if the updater was
  started - the caller must then terminate the application immediately. AProgress
  is marshalled to the main thread. }
function UDAWApplyUpdate(out AErrorMessage: string;
  const AProgress: TUDAWUpdateProgress = nil): Boolean;

{ Shows the tamper notice (decrypted only at this moment). The caller then
  terminates the application. }
procedure UDAWShowPiracyNotice;

{ True if UDAWUpdater.exe sits beside the running executable. }
function UDAWUpdaterPresent: Boolean;

{ Startup variants: run on a background thread while the main thread pumps its
  message queue against a hard deadline (called before Application.Run). }
function UDAWCheckForUpdateBounded(out AInfo: TUDAWUpdateInfo; out AErrorMessage: string): Boolean;
function UDAWApplyUpdateBounded(out AErrorMessage: string;
  const AProgress: TUDAWUpdateProgress = nil): Boolean;

implementation

uses
  System.SysUtils, System.Classes, System.JSON, System.Hash, System.IOUtils,
  System.Generics.Collections, System.Math, System.Net.HttpClient, System.Zip, Winapi.Windows,
  Winapi.ShellAPI, Vcl.Forms,
  UDAW.Types, UDAW.Version, UDAW.Licensing, UDAW.Paths;   // Licensing: shared server-access constants only; registration itself is disabled

const
  UDAW_VERSION_URL_WIN64 = UDAW_WEB_DOMAIN + '/udaw-version-win64.json';
  UDAW_DOWNLOAD_URL = UDAW_WEB_DOMAIN + '/udaw-download.php';
  UDAW_UPDATER_EXE = 'UDAWUpdater.exe';

var
  GPendingPackage, GPendingSha256, GPendingPlatform: string;
  GHavePending: Boolean;

// Dotted, purely numeric version strings; missing trailing components
// compare as zero.
function CompareVersions(const A, B: string): Integer;
var
  PartsA, PartsB: TArray<string>;
  I, ValA, ValB: Integer;
begin
  PartsA := A.Split(['.']);
  PartsB := B.Split(['.']);
  Result := 0;
  for I := 0 to Max(High(PartsA), High(PartsB)) do
  begin
    if I <= High(PartsA) then ValA := StrToIntDef(PartsA[I], 0) else ValA := 0;
    if I <= High(PartsB) then ValB := StrToIntDef(PartsB[I], 0) else ValB := 0;
    if ValA <> ValB then Exit(ValA - ValB);
  end;
end;

const
  // Notice text, stored only in enciphered form (no plain string in the binary).
  PIRACY_CIPHER: array[0..47] of Byte = (
    $0B,$C1,$93,$F4,$59,$B2,$9C,$3E,$AA,$D8,$A7,$BA,$1C,$7E,$D1,$06,
    $83,$54,$A9,$E1,$56,$E1,$AB,$A2,$3F,$A2,$3B,$BF,$5D,$2D,$7B,$FA,
    $6F,$CD,$ED,$1C,$AC,$25,$A1,$8E,$D6,$E5,$E6,$CD,$D7,$FA,$0F,$0F);
  PIRACY_CIPHER_TAIL: Byte = $76;

function PiracyNotice: string;
var
  I: Integer;
  B, K: Byte;
  Bytes: TBytes;
begin
  SetLength(Bytes, Length(PIRACY_CIPHER) + 1);
  for I := 0 to High(Bytes) do
  begin
    if I < Length(PIRACY_CIPHER) then B := PIRACY_CIPHER[I] else B := PIRACY_CIPHER_TAIL;
    K := Byte(((I * 167 + 41) and 255) xor (((I shr 1) * 29 + 113) and 255) xor
      ((I * I + 7) and 255));
    Bytes[I] := B xor K;
  end;
  Result := TEncoding.ASCII.GetString(Bytes);
end;

procedure UDAWShowPiracyNotice;
begin
  MessageBoxW(0, PChar(PiracyNotice), 'Ultimanium Designs', MB_OK or MB_ICONSTOP or MB_TOPMOST);
end;

function OrdinalLineCompare(List: TStringList; A, B: Integer): Integer;
begin
  Result := CompareStr(List[A], List[B]);
end;

// Digest of the canonical file list, signed as part of the manifest:
// lower-case '/'-separated path ':' sha256 '#10', ordinal-sorted by path.
function FilesDigest(AFiles: TJSONObject): string;
var
  Lines: TStringList;
  I: Integer;
  All: string;
begin
  Lines := TStringList.Create;
  try
    for I := 0 to AFiles.Count - 1 do
      Lines.Add(LowerCase(AFiles.Pairs[I].JsonString.Value) + ':' +
        LowerCase(AFiles.Pairs[I].JsonValue.Value));
    Lines.CaseSensitive := True;
    Lines.CustomSort(OrdinalLineCompare);
    All := '';
    for I := 0 to Lines.Count - 1 do All := All + Lines[I] + #10;
    Result := LowerCase(THashSHA2.GetHashString(All, SHA256));
  finally
    Lines.Free;
  end;
end;

// True when every manifest file exists beside the exe with the listed hash.
// An unreadable file (I/O hiccup) is not held against the user.
function FilesMatch(AFiles: TJSONObject): Boolean;
var
  I: Integer;
  Dir, Path: string;
begin
  Result := True;
  Dir := ExtractFilePath(ParamStr(0));
  for I := 0 to AFiles.Count - 1 do
  begin
    Path := Dir + StringReplace(AFiles.Pairs[I].JsonString.Value, '/', PathDelim, [rfReplaceAll]);
    if not TFile.Exists(Path) then Exit(False);
    try
      if not SameText(THashSHA2.GetHashStringFromFile(Path, SHA256),
        AFiles.Pairs[I].JsonValue.Value) then Exit(False);
    except
      // cannot hash: skip this file
    end;
  end;
end;

function UDAWUpdaterPresent: Boolean;
begin
  Result := TFile.Exists(ExtractFilePath(ParamStr(0)) + UDAW_UPDATER_EXE);
end;

function UDAWCheckForUpdate(out AInfo: TUDAWUpdateInfo; out AErrorMessage: string): Boolean;
var
  Http: THTTPClient;
  Response: IHTTPResponse;
  Root: TJSONValue;
  Payload, ExpectedSig, ActualSig, ExeSha256, ActualExeSha: string;
  FilesVal: TJSONValue;
begin
  Result := False;
  AInfo := Default(TUDAWUpdateInfo);
  AInfo.CurrentVersion := UDAWNumericVersion;
  AErrorMessage := '';
  GHavePending := False;
  Http := THTTPClient.Create;
  Root := nil;
  try
    try
      Http.ConnectionTimeout := 10000;
      Http.ResponseTimeout := 10000;
      Response := Http.Get(UDAW_VERSION_URL_WIN64);
      if Response.StatusCode <> 200 then
      begin
        AErrorMessage := Format('The update server returned HTTP %d.', [Response.StatusCode]);
        Exit;
      end;
      Root := TJSONObject.ParseJSONValue(Response.ContentAsString(TEncoding.UTF8));
      if not Assigned(Root) or not (Root is TJSONObject) then
      begin
        AErrorMessage := 'The update version file could not be read.';
        Exit;
      end;
      AInfo.ServerVersion := TJSONObject(Root).GetValue<string>('version', '');
      GPendingPackage := TJSONObject(Root).GetValue<string>('package', '');
      GPendingSha256 := LowerCase(TJSONObject(Root).GetValue<string>('sha256', ''));
      GPendingPlatform := TJSONObject(Root).GetValue<string>('platform', '');
      ExeSha256 := LowerCase(TJSONObject(Root).GetValue<string>('exe_sha256', ''));
      if (AInfo.ServerVersion = '') or (GPendingPackage = '') or
        (GPendingSha256 = '') or (ExeSha256 = '') then
      begin
        AErrorMessage := 'The update version file is missing required fields.';
        Exit;
      end;
      FilesVal := TJSONObject(Root).GetValue('files');
      if not (FilesVal is TJSONObject) then
      begin
        AErrorMessage := 'The update version file has no file manifest.';
        Exit;
      end;
      Payload := AInfo.ServerVersion + '|' + GPendingPlatform + '|' +
        GPendingPackage + '|' + GPendingSha256 + '|' + ExeSha256 + '|' +
        FilesDigest(TJSONObject(FilesVal));
      ExpectedSig := LowerCase(TJSONObject(Root).GetValue<string>('sig', ''));
      ActualSig := LowerCase(THashSHA2.GetHMAC(Payload, UDAW_SYSTEM_ACCESS_KEY, SHA256));
      if (ExpectedSig = '') or (ExpectedSig <> ActualSig) then
      begin
        AErrorMessage := 'The update version file failed signature verification and cannot be trusted.';
        Exit;
      end;

      AInfo.UpdateAvailable := CompareVersions(AInfo.ServerVersion, AInfo.CurrentVersion) > 0;
      GHavePending := AInfo.UpdateAvailable;

      // Online executable checksum: only meaningful for the exact published
      // build. A newer local build (development) or an older one (about to be
      // updated) has no published hash to compare against.
      if CompareVersions(AInfo.ServerVersion, AInfo.CurrentVersion) = 0 then
      begin
        try
          ActualExeSha := LowerCase(THashSHA2.GetHashStringFromFile(ParamStr(0), SHA256));
          AInfo.ExeMismatch := ActualExeSha <> ExeSha256;
        except
          AInfo.ExeMismatch := False; // cannot hash: do not punish an I/O hiccup
        end;
        AInfo.FilesMismatch := not FilesMatch(TJSONObject(FilesVal));
        {$IFDEF RELEASE}
        // registration disabled: no licence edition to downgrade on a mismatch
        // if AInfo.ExeMismatch or AInfo.FilesMismatch then
        //   TUDAWLicense.TamperDetected := True;
        {$ENDIF}
      end;
      Result := True;
    except
      on E: Exception do
        AErrorMessage := 'Could not check for updates: ' + E.Message;
    end;
  finally
    Root.Free;
    Http.Free;
  end;
end;

// CreateProcess rather than ShellExecute: the shell path runs a SmartScreen
// reputation check on an unsigned helper. Only if the child demands elevation
// the parent lacks (ERROR_ELEVATION_REQUIRED) fall back to ShellExecute, which
// raises the standard UAC prompt.
function LaunchUpdater(const AUpdaterPath, AStagingRoot, AMainExeName,
  AWorkingDir: string): Boolean;
const
  ERROR_ELEVATION_REQUIRED = DWORD(740);
var
  CommandLine, Params: string;
  StartupInfo: TStartupInfo;
  ProcessInfo: TProcessInformation;
begin
  Params := '"' + AStagingRoot + '" "' + AMainExeName + '"';
  CommandLine := '"' + AUpdaterPath + '" ' + Params;
  UniqueString(CommandLine);
  ZeroMemory(@StartupInfo, SizeOf(StartupInfo));
  StartupInfo.cb := SizeOf(StartupInfo);
  if CreateProcess(nil, PChar(CommandLine), nil, nil, False, 0, nil,
    PChar(AWorkingDir), StartupInfo, ProcessInfo) then
  begin
    CloseHandle(ProcessInfo.hThread);
    CloseHandle(ProcessInfo.hProcess);
    Exit(True);
  end;
  if GetLastError <> ERROR_ELEVATION_REQUIRED then
    Exit(False);
  Result := NativeInt(ShellExecute(0, 'open', PChar(AUpdaterPath),
    PChar(Params), PChar(AWorkingDir), SW_SHOWNORMAL)) > 32;
end;

function UDAWApplyUpdate(out AErrorMessage: string;
  const AProgress: TUDAWUpdateProgress): Boolean;
var
  Http: THTTPClient;
  Response: IHTTPResponse;
  StagingRoot, ZipPath, ActualSha256, UpdaterExePath, MainExeName: string;
  FileStream: TFileStream;
  Guid: TGUID;
  LastPercent: Integer;
  Report: TProc<string, Integer, Integer>;
begin
  Result := False;
  AErrorMessage := '';
  Report :=
    procedure(ADetail: string; APosition, ATotal: Integer)
    begin
      if not Assigned(AProgress) then Exit;
      TThread.Queue(nil,
        procedure
        begin
          AProgress(ADetail, APosition, ATotal);
        end);
    end;
  if not GHavePending then
  begin
    AErrorMessage := 'No verified update is pending.';
    Exit;
  end;
  UpdaterExePath := ExtractFilePath(ParamStr(0)) + UDAW_UPDATER_EXE;
  if not TFile.Exists(UpdaterExePath) then
  begin
    AErrorMessage := UDAW_UPDATER_EXE + ' was not found alongside this application.';
    Exit;
  end;
  Http := THTTPClient.Create;
  try
    try
      Http.ConnectionTimeout := 30000;
      Http.ResponseTimeout := 120000;
      // Same header udaw-download.php requires. Not the security boundary
      // (the ZIP's SHA-256, checked below against the HMAC-signed manifest
      // value, is) - it only keeps the package from being casually scraped.
      Http.CustomHeaders[UDAW_CLIENT_HEADER_NAME] := UDAW_CLIENT_HEADER_VALUE;
      CreateGUID(Guid);
      ForceDirectories(Paths.Temp);
      StagingRoot := TPath.Combine(Paths.Temp,
        'UDAWUpdate-' + Copy(GUIDToString(Guid), 2, 36));
      TDirectory.CreateDirectory(StagingRoot);
      ZipPath := TPath.Combine(Paths.Temp, GPendingPackage);
      LastPercent := -1;
      Http.ReceiveDataCallBack :=
        procedure(const Sender: TObject; AContentLength, AReadCount: Int64;
          var AAbort: Boolean)
        var
          Percent: Integer;
        begin
          if AContentLength > 0 then
          begin
            Percent := Round(AReadCount * 100 / AContentLength);
            if Percent <> LastPercent then
            begin
              LastPercent := Percent;
              Report(Format('Downloading the update %d MB of %d MB',
                [AReadCount div (1024 * 1024), AContentLength div (1024 * 1024)]),
                Percent, 100);
            end;
          end
          else if (AReadCount div (1024 * 1024)) <> LastPercent then
          begin
            LastPercent := Integer(AReadCount div (1024 * 1024));
            Report(Format('Downloading the update %d MB received', [LastPercent]), 0, 1);
          end;
        end;
      Report('Downloading the update...', 0, 100);
      FileStream := TFileStream.Create(ZipPath, fmCreate);
      try
        Response := Http.Get(UDAW_DOWNLOAD_URL + '?platform=win64', FileStream);
        if Response.StatusCode <> 200 then
        begin
          AErrorMessage := Format('The update download server returned HTTP %d.', [Response.StatusCode]);
          Exit;
        end;
      finally
        FileStream.Free;
      end;
      Report('Verifying the update package...', 100, 100);
      ActualSha256 := LowerCase(THashSHA2.GetHashStringFromFile(ZipPath));
      if ActualSha256 <> GPendingSha256 then
      begin
        AErrorMessage := 'The downloaded update package failed verification and was discarded.';
        TFile.Delete(ZipPath);
        Exit;
      end;
      Report('Preparing the update...', 100, 100);
      TZipFile.ExtractZipFile(ZipPath, StagingRoot);
      TFile.Delete(ZipPath);

      MainExeName := ExtractFileName(ParamStr(0));
      Report('Restarting to complete the update...', 100, 100);
      if not LaunchUpdater(UpdaterExePath, StagingRoot, MainExeName,
        ExtractFilePath(ParamStr(0))) then
      begin
        AErrorMessage := UDAW_UPDATER_EXE + ' could not be started to apply the update.';
        Exit;
      end;
      Result := True;
    except
      on E: Exception do
        AErrorMessage := 'Could not download the update: ' + E.Message;
    end;
  finally
    Http.Free;
  end;
end;

type
  TBoundedWork = reference to function(out AError: string): Boolean;

function RunBoundedOnBackground(const AWork: TBoundedWork;
  ADeadlineMs: Cardinal; out AErrorMessage: string): Boolean;
var
  Done, ThreadResult: Boolean;
  ThreadError: string;
  Deadline: Cardinal;
begin
  Done := False;
  ThreadResult := False;
  ThreadError := '';
  TThread.CreateAnonymousThread(
    procedure
    var
      LocalResult: Boolean;
      LocalError: string;
    begin
      LocalResult := AWork(LocalError);
      TThread.Queue(nil,
        procedure
        begin
          ThreadResult := LocalResult;
          ThreadError := LocalError;
          Done := True;
        end);
    end).Start;

  Deadline := TThread.GetTickCount + ADeadlineMs;
  while not Done and (TThread.GetTickCount < Deadline) do
  begin
    Application.ProcessMessages;
    Sleep(10);
  end;

  if not Done then
  begin
    AErrorMessage := 'The operation did not complete within a reasonable time. ' +
      'Check your internet connection and try again.';
    Exit(False);
  end;
  AErrorMessage := ThreadError;
  Result := ThreadResult;
end;

function UDAWCheckForUpdateBounded(out AInfo: TUDAWUpdateInfo; out AErrorMessage: string): Boolean;
var
  Info: TUDAWUpdateInfo;
begin
  Info := Default(TUDAWUpdateInfo);
  Result := RunBoundedOnBackground(
    function(out AError: string): Boolean
    begin
      Result := UDAWCheckForUpdate(Info, AError);
    end, 25000, AErrorMessage);
  AInfo := Info;
  if not Result then AInfo.UpdateAvailable := False;
end;

function UDAWApplyUpdateBounded(out AErrorMessage: string;
  const AProgress: TUDAWUpdateProgress): Boolean;
begin
  Result := RunBoundedOnBackground(
    function(out AError: string): Boolean
    begin
      Result := UDAWApplyUpdate(AError, AProgress);
    end, 600000, AErrorMessage);
end;

end.
