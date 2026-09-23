unit UDAW.Licensing;

{ Online registration for UDAW (Ultimanium Digital Audio Workstation, product
  ID 18), ported from the CyberRealm/Phoenix clients, which talk to the same
  server with the same contract.

  CONTRACT WITH THE SERVER (https://ultimanium.com/system-verify.php)
  A dedicated branch of system-verify.php recognises UDAW by the X-UDAW-Client
  HTTP header (UDAW_CLIENT_HEADER_VALUE), never by anything in the JSON body,
  and checks an HMAC-SHA256 signature over
  "<unix timestamp>|<username>|<product id>|<serial>" keyed with
  UDAW_SYSTEM_ACCESS_KEY, which must equal the server's
  MyGlobals::SYSTEM_ACCESS_KEY (the same shared secret every Delphi client uses).

  A "serial" is one purchased seat, pinned by the server to the machine that
  activated it (matched by ComputeMachineFingerprint) and refused to a second
  machine while checked out. That server-side refusal is the real anti-piracy
  control; the executable checksum check against the signed online manifest
  lives in UDAW.Update.

  LOCAL CREDENTIAL CACHE: the username/password/serial JSON is stored through
  UDAW.SecureStorage (Windows DPAPI, bound to this Windows account) so a
  returning user is not asked to retype credentials on every launch.

  OFFLINE GRACE: an unreachable server is "no verdict", never "no" - the app
  stays registered on the cached credentials and keeps re-verifying on the
  heartbeat timer until the server gives a definitive OK/DENIED/BLOCKED.

  UNREGISTERED (LITE) EDITION: everything works except exporting of any kind
  and any use of AI. Callers gate those with TUDAWLicense.IsRegistered. }

interface

uses
  System.SysUtils, System.Classes;

const
  // Must equal MyGlobals::SYSTEM_ACCESS_KEY in constants.php.
  UDAW_SYSTEM_ACCESS_KEY = 'UD_S3CR3T_2026!xZ9#qLmP';
  // Must equal MyGlobals::UDAW_CLIENT_HEADER_ID in constants.php.
  UDAW_CLIENT_HEADER_VALUE = 'UDAW-Client-2026-Ultimanium';
  UDAW_CLIENT_HEADER_NAME = 'X-UDAW-Client';
  UDAW_VERIFY_URL = 'https://ultimanium.com/system-verify.php';
  UDAW_PRODUCT_ID = 18;
  // The server expires an un-heartbeated session after 300 seconds.
  UDAW_HEARTBEAT_INTERVAL_MS = 120 * 1000;
  // How long UDAW may keep running after it loses the licence server before it
  // shuts itself down to force a re-verification. Reconnecting within this
  // window cancels the countdown.
  UDAW_OFFLINE_LIMIT_SECONDS = 24 * 60 * 60;

type
  TLicenseStatus = (lsUnknown, lsOK, lsDenied, lsBlocked, lsOffline);

  TLicenseResult = record
    Status: TLicenseStatus;
    Message: string;
  end;

  TUDAWLicense = class
  public
    /// <summary>Set by the UI so it can repaint the instant registration state
    /// changes (success, mid-session revocation, unregister).</summary>
    class var OnStateChanged: TProc;
    /// <summary>Set by UDAW.Update when the running EXE's SHA-256 does not
    /// match the signed online manifest for its own version. Forces the
    /// unregistered edition for the rest of the run, whatever any licence
    /// check says.</summary>
    class var TamperDetected: Boolean;

    /// <summary>Synchronous call to system-verify.php. Never call from the UI
    /// thread - it does real network and (first use) WMI I/O.</summary>
    class function Verify(const AUsername, APassword, ASerial: string;
      ASilent: Boolean): TLicenseResult;
    /// <summary>Startup variant: verifies the DPAPI-cached credentials on a
    /// background thread while pumping messages against a hard deadline, so
    /// the splash screen can stay up without ever hanging startup. On
    /// timeout the result is lsOffline (cached credentials keep the app
    /// registered, offline-grace).</summary>
    class function AttemptSilentVerifyBounded(ADeadlineMs: Cardinal = 15000): TLicenseResult;
    /// <summary>Foreground registration from the Registration tab. The callback
    /// is marshalled to the UI thread.</summary>
    class procedure VerifyAsync(const AUsername, APassword, ASerial: string;
      AOnDone: TProc<TLicenseResult>);

    class procedure StartHeartbeat;
    class procedure StopHeartbeat;
    /// <summary>Ends this run's session (frees the seat for a relaunch) but
    /// keeps the cached credentials. Blocking with a short timeout - call on
    /// application exit.</summary>
    class procedure EndSession;
    /// <summary>Unregister: releases the seat and forgets the cached
    /// credentials on this machine.</summary>
    class procedure Unregister;

    class function IsRegistered: Boolean;
    class function CurrentEdition: string;
    class function RegisteredUsername: string;
    class function LastMessage: string;
    class function IsOfflineGrace: Boolean;
    /// <summary>Seconds left before UDAW must shut down because the licence
    /// server has been unreachable; -1 while the connection is fine. The
    /// countdown starts when the connection is first lost (persisted, so a
    /// restart does not reset it) and is cancelled by any successful
    /// verification.</summary>
    class function OfflineSecondsRemaining: Integer;
    /// <summary>True once the offline countdown has reached zero.</summary>
    class function OfflineExpired: Boolean;
    class function HasCachedCredentials: Boolean;
    class function CachedUsername: string;
    class function CachedSerial: string;
  private
    class procedure HeartbeatTick(Sender: TObject);
  end;

implementation

uses
  System.Threading, System.JSON, System.Hash, System.SyncObjs,
  System.DateUtils, System.Variants,
  Winapi.Windows, Winapi.ActiveX, System.Win.ComObj,
  System.Net.HttpClient, System.Net.URLClient, System.NetConsts,
  Vcl.Forms, Vcl.ExtCtrls,
  UDAW.Logging, UDAW.SecureStorage, UDAW.App;

const
  SECRET_KEY = 'udaw.license';

var
  GLock: TCriticalSection;
  GRegistered: Boolean;
  GOfflineGrace: Boolean;
  GSessionID: string;
  GRegisteredUsername: string;
  GLastMessage: string;
  GHeartbeatTimer: TTimer;
  GPendingTasks: Integer;
  GCachedFingerprint: string;
  GOfflineSince: TDateTime;   // UTC; 0 = connection fine

const
  OFFLINE_SECRET_KEY = 'udaw.license.offline';

function NowUtc: TDateTime;
begin
  Result := TTimeZone.Local.ToUniversalTime(Now);
end;

{ ------------------------------------------------------------------ fingerprint }

function GetSystemVolumeSerial: string;
var
  VolumeSerial, MaxComponentLength, FileSystemFlags: DWORD;
  VolumeName, FileSystemName: array[0..MAX_PATH] of Char;
  SystemDir: array[0..MAX_PATH] of Char;
  RootPath: string;
begin
  Result := '';
  if GetSystemDirectory(SystemDir, MAX_PATH) = 0 then Exit;
  RootPath := ExtractFileDrive(SystemDir) + '\';
  if GetVolumeInformation(PChar(RootPath), VolumeName, MAX_PATH, @VolumeSerial,
    MaxComponentLength, FileSystemFlags, FileSystemName, MAX_PATH) then
    Result := IntToHex(VolumeSerial, 8);
end;

function GetWmiIdentifier(const AWmiClass, AProperty: string): string;
var
  Locator, Service, Items, Item: OleVariant;
  Enum: IEnumVariant;
  Fetched: LongWord;
begin
  Result := '';
  try
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Service := Locator.ConnectServer('.', 'root\CIMV2');
    Items := Service.ExecQuery('SELECT ' + AProperty + ' FROM ' + AWmiClass);
    Enum := IUnknown(Items._NewEnum) as IEnumVariant;
    if Enum.Next(1, Item, Fetched) = S_OK then
    begin
      if not VarIsNull(Item.Properties_.Item(AProperty).Value) then
        Result := Trim(VarToStr(Item.Properties_.Item(AProperty).Value));
    end;
  except
    Result := '';
  end;
end;

function ComputeMachineFingerprint: string;
var
  Raw: string;
  Coinitialized: HRESULT;
begin
  GLock.Enter;
  try
    if GCachedFingerprint <> '' then Exit(GCachedFingerprint);
  finally
    GLock.Leave;
  end;
  Coinitialized := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  try
    Raw := GetSystemVolumeSerial + '|' +
      GetWmiIdentifier('Win32_ComputerSystemProduct', 'UUID') + '|' +
      GetWmiIdentifier('Win32_BaseBoard', 'SerialNumber') + '|' +
      GetWmiIdentifier('Win32_Processor', 'ProcessorId');
  finally
    if Succeeded(Coinitialized) then CoUninitialize;
  end;
  Result := LowerCase(THashSHA2.GetHashString(Raw, SHA256));
  GLock.Enter;
  try
    GCachedFingerprint := Result;
  finally
    GLock.Leave;
  end;
end;

function HmacSha256Hex(const APayload, ASecret: string): string;
begin
  Result := LowerCase(THashSHA2.GetHMAC(APayload, ASecret, SHA256));
end;

{ ------------------------------------------------------------------ local cache }

procedure SaveCachedCredentials(const AUsername, APassword, ASerial: string);
var
  Root: TJSONObject;
begin
  if (App = nil) or (App.Secure = nil) or not App.Secure.IsAvailable then Exit;
  Root := TJSONObject.Create;
  try
    Root.AddPair('username', AUsername);
    Root.AddPair('password', APassword);
    Root.AddPair('serial', ASerial);
    try
      App.Secure.SetSecret(SECRET_KEY, Root.ToJSON);
    except
      on E: Exception do
        Logger.Warn('license', 'Could not cache credentials: ' + E.Message);
    end;
  finally
    Root.Free;
  end;
end;

function LoadCachedCredentials(out AUsername, APassword, ASerial: string): Boolean;
var
  Plain: string;
  Root: TJSONValue;
begin
  Result := False;
  AUsername := ''; APassword := ''; ASerial := '';
  if (App = nil) or (App.Secure = nil) or not App.Secure.IsAvailable then Exit;
  try
    if not App.Secure.GetSecret(SECRET_KEY, Plain) then Exit;
    Root := TJSONObject.ParseJSONValue(Plain);
    if not (Root is TJSONObject) then
    begin
      Root.Free;
      Exit;
    end;
    try
      AUsername := TJSONObject(Root).GetValue<string>('username', '');
      APassword := TJSONObject(Root).GetValue<string>('password', '');
      ASerial := TJSONObject(Root).GetValue<string>('serial', '');
      Result := (AUsername <> '') and (APassword <> '') and (ASerial <> '');
    finally
      Root.Free;
    end;
  except
    Result := False;
  end;
end;

procedure ClearCachedCredentials;
begin
  if (App = nil) or (App.Secure = nil) or not App.Secure.IsAvailable then Exit;
  try
    App.Secure.DeleteSecret(SECRET_KEY);
  except
    on E: Exception do
      Logger.Warn('license', 'Could not clear cached credentials: ' + E.Message);
  end;
end;

{ ------------------------------------------------------------------ HTTP }

function CallSystemVerify(const AAction, AUsername, APassword, ASerial,
  AHostname, ASessionID: string; ATimeoutMs: Integer = 10000): TLicenseResult;
var
  Http: THTTPClient;
  Body: TJSONObject;
  Response: IHTTPResponse;
  Timestamp: Int64;
  Signature, PayloadToSign, ResponseText, StatusStr: string;
  ResponseJson: TJSONValue;
  Stream: TStringStream;
begin
  Result := Default(TLicenseResult);
  Result.Status := lsOffline;
  Timestamp := DateTimeToUnix(TTimeZone.Local.ToUniversalTime(Now), True);
  PayloadToSign := IntToStr(Timestamp) + '|' + AUsername + '|' +
    IntToStr(UDAW_PRODUCT_ID) + '|' + ASerial;
  Signature := HmacSha256Hex(PayloadToSign, UDAW_SYSTEM_ACCESS_KEY);

  Body := TJSONObject.Create;
  Http := THTTPClient.Create;
  try
    try
      Body.AddPair('client', 'udaw');
      Body.AddPair('ts', TJSONNumber.Create(Timestamp));
      Body.AddPair('username', AUsername);
      Body.AddPair('password', APassword);
      Body.AddPair('product_id', TJSONNumber.Create(UDAW_PRODUCT_ID));
      Body.AddPair('serial', ASerial);
      Body.AddPair('hostname', AHostname);
      Body.AddPair('session_id', ASessionID);
      Body.AddPair('action', AAction);
      Body.AddPair('sig', Signature);

      Http.ContentType := 'application/json';
      Http.CustomHeaders[UDAW_CLIENT_HEADER_NAME] := UDAW_CLIENT_HEADER_VALUE;
      Http.ConnectionTimeout := ATimeoutMs;
      Http.ResponseTimeout := ATimeoutMs;

      Stream := TStringStream.Create(Body.ToJSON, TEncoding.UTF8);
      try
        Response := Http.Post(UDAW_VERIFY_URL, Stream, nil,
          [TNetHeader.Create('Content-Type', 'application/json')]);
      finally
        Stream.Free;
      end;

      ResponseText := Response.ContentAsString(TEncoding.UTF8);
      ResponseJson := TJSONObject.ParseJSONValue(ResponseText);
      if not Assigned(ResponseJson) then
      begin
        Result.Message := 'The licence server returned an unreadable response.';
        Exit;
      end;
      try
        if ResponseJson is TJSONObject then
        begin
          StatusStr := TJSONObject(ResponseJson).GetValue<string>('status', 'ERROR');
          Result.Message := TJSONObject(ResponseJson).GetValue<string>('message', '');
          GLock.Enter;
          try
            GSessionID := TJSONObject(ResponseJson).GetValue<string>('session_id', GSessionID);
          finally
            GLock.Leave;
          end;
          if StatusStr = 'OK' then Result.Status := lsOK
          else if StatusStr = 'BLOCKED' then Result.Status := lsBlocked
          else Result.Status := lsDenied;
        end;
      finally
        ResponseJson.Free;
      end;
    except
      on E: Exception do
      begin
        Result.Status := lsOffline;
        Result.Message := 'Could not reach the licence server: ' + E.Message;
      end;
    end;
  finally
    Body.Free;
    Http.Free;
  end;
end;

{ ------------------------------------------------------------------ state helpers }

procedure NotifyStateChanged;
begin
  if Assigned(TUDAWLicense.OnStateChanged) then
    // Always delivered on the main thread: callers (verify tasks, heartbeat
    // tasks) run on worker threads and the callback touches VCL controls.
    TThread.Queue(nil,
      procedure
      begin
        try
          TUDAWLicense.OnStateChanged();
        except
          on E: Exception do
            Logger.Warn('license', 'OnStateChanged: ' + E.Message);
        end;
      end);
end;

{ Connection lost: start the shutdown countdown, unless one is already running
  (in memory, or persisted from before a restart - so relaunching cannot buy
  a fresh 24 hours). }
procedure MarkOffline;
var
  Stored: string;
  Parsed: TDateTime;
begin
  GLock.Enter;
  try
    if GOfflineSince <> 0 then Exit;
    GOfflineSince := NowUtc;
    if (App <> nil) and (App.Secure <> nil) and App.Secure.IsAvailable then
      try
        if App.Secure.GetSecret(OFFLINE_SECRET_KEY, Stored) and
           TryISO8601ToDate(Stored, Parsed, False) and (Parsed <= NowUtc) then
          GOfflineSince := Parsed
        else
          App.Secure.SetSecret(OFFLINE_SECRET_KEY, DateToISO8601(GOfflineSince, False));
      except
        on E: Exception do
          Logger.Warn('license', 'Could not persist offline timer: ' + E.Message);
      end;
  finally
    GLock.Leave;
  end;
  Logger.Warn('license', 'Licence server unreachable - offline countdown running.');
end;

{ Connection (re-)established: abort the countdown and carry on as normal. }
procedure MarkOnline;
begin
  GLock.Enter;
  try
    GOfflineSince := 0;
  finally
    GLock.Leave;
  end;
  if (App <> nil) and (App.Secure <> nil) and App.Secure.IsAvailable then
    try
      App.Secure.DeleteSecret(OFFLINE_SECRET_KEY);
    except
    end;
end;

procedure ApplySuccess(const AUsername, ASessionID: string);
begin
  MarkOnline;
  GLock.Enter;
  try
    GRegistered := True;
    GOfflineGrace := False;
    GSessionID := ASessionID;
    GRegisteredUsername := AUsername;
    GLastMessage := 'Registered.';
  finally
    GLock.Leave;
  end;
  Logger.Info('license', 'UDAW registered for ' + AUsername + '.');
  NotifyStateChanged;
end;

procedure ApplyOfflineGrace;
begin
  MarkOffline;
  GLock.Enter;
  try
    GRegistered := True;
    GOfflineGrace := True;
    GSessionID := '';
    GLastMessage := 'Licence server unreachable - running on cached registration.';
  finally
    GLock.Leave;
  end;
  Logger.Warn('license', 'Licence check offline - continuing on cached credentials.');
  NotifyStateChanged;
end;

procedure ApplyFailure(const AMessage: string);
begin
  MarkOnline;   // unregistered: nothing left to count down
  GLock.Enter;
  try
    GRegistered := False;
    GOfflineGrace := False;
    GSessionID := '';
    if AMessage <> '' then GLastMessage := AMessage
    else GLastMessage := 'Registration could not be completed.';
  finally
    GLock.Leave;
  end;
  Logger.Warn('license', 'UDAW running unregistered: ' + GLastMessage);
  NotifyStateChanged;
end;

{ ------------------------------------------------------------------ TUDAWLicense }

class function TUDAWLicense.Verify(const AUsername, APassword, ASerial: string;
  ASilent: Boolean): TLicenseResult;
var
  Fingerprint, Session: string;
begin
  Fingerprint := ComputeMachineFingerprint;
  Result := CallSystemVerify('verify', AUsername, APassword, ASerial, Fingerprint, '');
  case Result.Status of
    lsOK:
      begin
        GLock.Enter;
        try
          Session := GSessionID;
        finally
          GLock.Leave;
        end;
        SaveCachedCredentials(AUsername, APassword, ASerial);
        ApplySuccess(AUsername, Session);
      end;
    lsOffline:
      // A silent check with cached credentials is "no verdict" -> grace.
      // A manual registration attempt with an unreachable server is a
      // failure: nothing has ever been verified for these credentials.
      if ASilent then ApplyOfflineGrace
      else ApplyFailure(Result.Message);
  else
    begin
      // Definitive refusal. A silent (cached) refusal means the licence was
      // revoked/blocked/moved: forget the cache so it is not retried forever.
      ClearCachedCredentials;
      ApplyFailure(Result.Message);
    end;
  end;
end;

class function TUDAWLicense.AttemptSilentVerifyBounded(ADeadlineMs: Cardinal): TLicenseResult;
var
  Username, Password, Serial: string;
  Done: Boolean;
  Deadline: Cardinal;
  ThreadResult: TLicenseResult;
begin
  Result := Default(TLicenseResult);
  Result.Status := lsDenied;
  Result.Message := 'No registration is stored on this machine.';
  if not LoadCachedCredentials(Username, Password, Serial) then
  begin
    ApplyFailure(Result.Message);
    Exit;
  end;

  Done := False;
  ThreadResult := Default(TLicenseResult);
  TThread.CreateAnonymousThread(
    procedure
    var
      R: TLicenseResult;
    begin
      R := Verify(Username, Password, Serial, True);
      TThread.Queue(nil,
        procedure
        begin
          ThreadResult := R;
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
    Result.Status := lsOffline;
    Result.Message := 'The licence server did not respond in time.';
    ApplyOfflineGrace;
    Exit;
  end;
  Result := ThreadResult;
end;

class procedure TUDAWLicense.VerifyAsync(const AUsername, APassword, ASerial: string;
  AOnDone: TProc<TLicenseResult>);
begin
  TInterlocked.Increment(GPendingTasks);
  TTask.Run(
    procedure
    var
      R: TLicenseResult;
    begin
      R := Verify(AUsername, APassword, ASerial, False);
      TThread.Queue(nil,
        procedure
        begin
          TInterlocked.Decrement(GPendingTasks);
          if Assigned(AOnDone) then AOnDone(R);
        end);
    end);
end;

class procedure TUDAWLicense.HeartbeatTick(Sender: TObject);
var
  SessionToCheck, Username, Password, Serial: string;
begin
  if GPendingTasks > 0 then Exit;

  GLock.Enter;
  try
    SessionToCheck := GSessionID;
  finally
    GLock.Leave;
  end;

  if SessionToCheck = '' then
  begin
    // Offline grace: no live session, but running on the cached credentials.
    // Keep silently re-verifying until the server answers definitively.
    if GOfflineGrace and LoadCachedCredentials(Username, Password, Serial) then
    begin
      TInterlocked.Increment(GPendingTasks);
      TTask.Run(
        procedure
        begin
          TUDAWLicense.Verify(Username, Password, Serial, True);
          TThread.Queue(nil, procedure begin TInterlocked.Decrement(GPendingTasks); end);
        end);
    end;
    Exit;
  end;

  TInterlocked.Increment(GPendingTasks);
  TTask.Run(
    procedure
    var
      R: TLicenseResult;
    begin
      R := CallSystemVerify('heartbeat', '', '', '', '', SessionToCheck);
      TThread.Queue(nil,
        procedure
        begin
          TInterlocked.Decrement(GPendingTasks);
          if R.Status = lsOK then
          begin
            if GOfflineSince <> 0 then
            begin
              MarkOnline;   // reconnected in time: countdown aborted
              Logger.Info('license', 'Licence server reachable again - offline countdown cancelled.');
              NotifyStateChanged;
            end;
            Exit;
          end;
          // A network problem is not a verdict - the server never said no,
          // but it starts the shutdown countdown.
          if R.Status = lsOffline then
          begin
            MarkOffline;
            NotifyStateChanged;
            Exit;
          end;
          // The server ended this session. Before interrupting the user,
          // silently re-present the cached machine-bound credentials - an
          // expiry on the same machine simply re-pins the seat. Only a second
          // explicit refusal drops to the unregistered edition. Re-verify on
          // a worker: Verify does network I/O.
          GLock.Enter;
          try
            GSessionID := '';
          finally
            GLock.Leave;
          end;
          if LoadCachedCredentials(Username, Password, Serial) then
          begin
            TInterlocked.Increment(GPendingTasks);
            TTask.Run(
              procedure
              begin
                TUDAWLicense.Verify(Username, Password, Serial, True);
                TThread.Queue(nil, procedure begin TInterlocked.Decrement(GPendingTasks); end);
              end);
          end
          else
            ApplyFailure('Your registration session ended: ' + R.Message);
        end);
    end);
end;

class function TUDAWLicense.OfflineSecondsRemaining: Integer;
var
  Since: TDateTime;
begin
  GLock.Enter;
  try
    Since := GOfflineSince;
  finally
    GLock.Leave;
  end;
  if Since = 0 then Exit(-1);
  Result := UDAW_OFFLINE_LIMIT_SECONDS - SecondsBetween(NowUtc, Since);
  if Result < 0 then Result := 0;
end;

class function TUDAWLicense.OfflineExpired: Boolean;
begin
  Result := OfflineSecondsRemaining = 0;
end;

class procedure TUDAWLicense.StartHeartbeat;
begin
  if GHeartbeatTimer = nil then
  begin
    GHeartbeatTimer := TTimer.Create(nil);
    GHeartbeatTimer.Interval := UDAW_HEARTBEAT_INTERVAL_MS;
    GHeartbeatTimer.OnTimer := HeartbeatTick;
  end;
  GHeartbeatTimer.Enabled := True;
end;

class procedure TUDAWLicense.StopHeartbeat;
begin
  if Assigned(GHeartbeatTimer) then
    GHeartbeatTimer.Enabled := False;
end;

class procedure TUDAWLicense.EndSession;
var
  SessionToRelease: string;
begin
  StopHeartbeat;
  GLock.Enter;
  try
    SessionToRelease := GSessionID;
    GSessionID := '';
  finally
    GLock.Leave;
  end;
  // Synchronous with a short timeout so the process does not exit before the
  // request is sent (a fire-and-forget task dies with the process).
  if SessionToRelease <> '' then
    CallSystemVerify('release', '', '', '', '', SessionToRelease, 3000);
end;

class procedure TUDAWLicense.Unregister;
var
  SessionToRelease: string;
begin
  StopHeartbeat;
  GLock.Enter;
  try
    SessionToRelease := GSessionID;
    GSessionID := '';
    GRegistered := False;
    GOfflineGrace := False;
    GRegisteredUsername := '';
    GLastMessage := 'Unregistered on this computer.';
  finally
    GLock.Leave;
  end;
  if SessionToRelease <> '' then
    TTask.Run(
      procedure
      begin
        CallSystemVerify('release', '', '', '', '', SessionToRelease);
      end);
  ClearCachedCredentials;
  NotifyStateChanged;
end;

class function TUDAWLicense.IsRegistered: Boolean;
begin
  if TamperDetected then Exit(False);
  GLock.Enter;
  try
    Result := GRegistered;
  finally
    GLock.Leave;
  end;
end;

class function TUDAWLicense.CurrentEdition: string;
begin
  if TamperDetected then Exit('Unregistered (modified executable)');
  if IsRegistered then
  begin
    if IsOfflineGrace then Result := 'Registered (offline)'
    else Result := 'Registered';
  end
  else Result := 'Unregistered';
end;

class function TUDAWLicense.RegisteredUsername: string;
begin
  GLock.Enter;
  try
    Result := GRegisteredUsername;
  finally
    GLock.Leave;
  end;
end;

class function TUDAWLicense.LastMessage: string;
begin
  GLock.Enter;
  try
    Result := GLastMessage;
  finally
    GLock.Leave;
  end;
end;

class function TUDAWLicense.IsOfflineGrace: Boolean;
begin
  GLock.Enter;
  try
    Result := GOfflineGrace;
  finally
    GLock.Leave;
  end;
end;

class function TUDAWLicense.HasCachedCredentials: Boolean;
var
  U, P, S: string;
begin
  Result := LoadCachedCredentials(U, P, S);
end;

class function TUDAWLicense.CachedUsername: string;
var
  P, S: string;
begin
  if not LoadCachedCredentials(Result, P, S) then Result := '';
end;

class function TUDAWLicense.CachedSerial: string;
var
  U, P: string;
begin
  if not LoadCachedCredentials(U, P, Result) then Result := '';
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  FreeAndNil(GHeartbeatTimer);
  GLock.Free;

end.
