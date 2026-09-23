unit UDAW.SecureStorage;
{$I udaw.inc}

{ OS-backed secret storage for API credentials (plan sections 30, 44).

    Windows : DPAPI (CryptProtectData/CryptUnprotectData), bound to the current
              user account. Encrypted blobs are kept, base64-encoded, in
              <config>/credentials.dpapi. Nothing is ever stored in plaintext.
    macOS   : the login Keychain, via /usr/bin/security.
    Linux   : the Secret Service (GNOME Keyring / KWallet) via `secret-tool`
              from libsecret. If `secret-tool` is not installed the provider
              reports IsAvailable = False and Set/Get/Delete raise
              EUDAWError(errSecureStorage) with an actionable message -
              there is deliberately NO weak home-grown fallback.

  Secrets are addressed by a short opaque key such as 'openai.api_key'. }

interface

uses
  SysUtils, Classes;

type
  ISecureStore = interface
    ['{2A9F5D31-7C48-4E2B-9B0A-6D5C1E884411}']
    function ProviderName: string;
    function IsAvailable: Boolean;
    procedure SetSecret(const AKey, AValue: string);
    function GetSecret(const AKey: string; out AValue: string): Boolean;
    function HasSecret(const AKey: string): Boolean;
    procedure DeleteSecret(const AKey: string);
  end;

{ Process-wide instance for the platform this build runs on. }
function SecureStore: ISecureStore;

{ Self-contained (no third-party library) base64 - exposed for reuse by
  anything else that needs to embed bytes in JSON/text, e.g. UDAW.AI.Suno's
  reference-audio upload. }
function Base64Encode(const Bytes: TBytes): string;

implementation

uses
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  {$IF DEFINED(UDAW_MACOS) OR DEFINED(UDAW_POSIX)}
  Process,
  {$IFEND}
  UDAW.Errors, UDAW.Paths;

const
  SECRET_SERVICE = 'UDAW';
  SUBSYS = 'SecureStorage';

{ ---------------- base64 (self-contained) ---------------- }

const
  B64: array[0..63] of AnsiChar =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function Base64Encode(const Bytes: TBytes): string;
var
  i, n: Integer;
  a, b, c: Byte;
  sb: TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    i := 0;
    n := Length(Bytes);
    while i < n do
    begin
      a := Bytes[i];
      sb.Append(Char(B64[a shr 2]));
      if i + 1 < n then
      begin
        b := Bytes[i + 1];
        sb.Append(Char(B64[((a and 3) shl 4) or (b shr 4)]));
        if i + 2 < n then
        begin
          c := Bytes[i + 2];
          sb.Append(Char(B64[((b and 15) shl 2) or (c shr 6)]));
          sb.Append(Char(B64[c and 63]));
        end
        else
        begin
          sb.Append(Char(B64[(b and 15) shl 2]));
          sb.Append('=');
        end;
      end
      else
      begin
        sb.Append(Char(B64[(a and 3) shl 4]));
        sb.Append('==');
      end;
      Inc(i, 3);
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function B64Val(C: Char): Integer;
begin
  case C of
    'A'..'Z': Result := Ord(C) - Ord('A');
    'a'..'z': Result := Ord(C) - Ord('a') + 26;
    '0'..'9': Result := Ord(C) - Ord('0') + 52;
    '+': Result := 62;
    '/': Result := 63;
  else
    Result := -1;
  end;
end;

function Base64Decode(const S: string): TBytes;
var
  i, outLen: Integer;
  quad: array[0..3] of Integer;
  q: Integer;
  tmp: TBytes;
begin
  SetLength(tmp, (Length(S) div 4 + 1) * 3);
  outLen := 0;
  q := 0;
  for i := 1 to Length(S) do
  begin
    if S[i] = '=' then
      Break;
    if (S[i] = #10) or (S[i] = #13) or (S[i] = ' ') then
      Continue;
    quad[q] := B64Val(S[i]);
    if quad[q] < 0 then
      Continue;
    Inc(q);
    if q = 4 then
    begin
      tmp[outLen] := Byte((quad[0] shl 2) or (quad[1] shr 4)); Inc(outLen);
      tmp[outLen] := Byte((quad[1] shl 4) or (quad[2] shr 2)); Inc(outLen);
      tmp[outLen] := Byte((quad[2] shl 6) or quad[3]);         Inc(outLen);
      q := 0;
    end;
  end;
  if q = 2 then
  begin
    tmp[outLen] := Byte((quad[0] shl 2) or (quad[1] shr 4)); Inc(outLen);
  end
  else if q = 3 then
  begin
    tmp[outLen] := Byte((quad[0] shl 2) or (quad[1] shr 4)); Inc(outLen);
    tmp[outLen] := Byte((quad[1] shl 4) or (quad[2] shr 2)); Inc(outLen);
  end;
  SetLength(tmp, outLen);
  Result := tmp;
end;

{ ================= Windows: DPAPI ================= }

{$IFDEF MSWINDOWS}
type
  DATA_BLOB = record
    cbData: DWORD;
    pbData: PByte;
  end;
  PDATA_BLOB = ^DATA_BLOB;

function CryptProtectData(pDataIn: PDATA_BLOB; szDataDescr: LPCWSTR;
  pOptionalEntropy: PDATA_BLOB; pvReserved: Pointer; pPromptStruct: Pointer;
  dwFlags: DWORD; pDataOut: PDATA_BLOB): BOOL; stdcall;
  external 'crypt32.dll' name 'CryptProtectData';

function CryptUnprotectData(pDataIn: PDATA_BLOB; ppszDataDescr: Pointer;
  pOptionalEntropy: PDATA_BLOB; pvReserved: Pointer; pPromptStruct: Pointer;
  dwFlags: DWORD; pDataOut: PDATA_BLOB): BOOL; stdcall;
  external 'crypt32.dll' name 'CryptUnprotectData';

type
  TWindowsDPAPIStore = class(TInterfacedObject, ISecureStore)
  private
    FFile: string;
    FList: TStringList;   // name = <#9> = base64(protected)
    procedure Load;
    procedure SaveAtomic;
    function Entropy(const AKey: string): TBytes;
  public
    constructor Create;
    destructor Destroy; override;
    function ProviderName: string;
    function IsAvailable: Boolean;
    procedure SetSecret(const AKey, AValue: string);
    function GetSecret(const AKey: string; out AValue: string): Boolean;
    function HasSecret(const AKey: string): Boolean;
    procedure DeleteSecret(const AKey: string);
  end;

constructor TWindowsDPAPIStore.Create;
begin
  inherited Create;
  FFile := Paths.Config + 'credentials.dpapi';
  FList := TStringList.Create;
  FList.NameValueSeparator := #9;
  FList.CaseSensitive := True;
  Load;
end;

destructor TWindowsDPAPIStore.Destroy;
begin
  FList.Free;
  inherited Destroy;
end;

procedure TWindowsDPAPIStore.Load;
begin
  FList.Clear;
  if FileExists(FFile) then
    FList.LoadFromFile(FFile);
end;

procedure TWindowsDPAPIStore.SaveAtomic;
var
  tmp: string;
begin
  tmp := FFile + '.tmp';
  if FileExists(tmp) then
    SysUtils.DeleteFile(tmp);
  FList.SaveToFile(tmp);
  if FileExists(FFile) then
    SysUtils.DeleteFile(FFile);
  if not RenameFile(tmp, FFile) then
    RaiseUDAWFmt(errSecureStorage, SUBSYS, 'Could not update "%s"', [FFile]);
end;

function TWindowsDPAPIStore.Entropy(const AKey: string): TBytes;
begin
  Result := TEncoding.UTF8.GetBytes('UDAW::secret::' + AKey);
end;

function TWindowsDPAPIStore.ProviderName: string;
begin
  Result := 'Windows DPAPI (per-user)';
end;

function TWindowsDPAPIStore.IsAvailable: Boolean;
begin
  Result := True;
end;

procedure TWindowsDPAPIStore.SetSecret(const AKey, AValue: string);
var
  inBlob, outBlob, entBlob: DATA_BLOB;
  plain, ent: TBytes;
  protectedBytes: TBytes;
begin
  if Trim(AKey) = '' then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'Empty secret key');
  plain := TEncoding.UTF8.GetBytes(AValue);
  ent := Entropy(AKey);

  FillChar(inBlob, SizeOf(inBlob), 0);
  FillChar(outBlob, SizeOf(outBlob), 0);
  FillChar(entBlob, SizeOf(entBlob), 0);
  if Length(plain) > 0 then
  begin
    inBlob.cbData := Length(plain);
    inBlob.pbData := @plain[0];
  end;
  entBlob.cbData := Length(ent);
  entBlob.pbData := @ent[0];

  if not CryptProtectData(@inBlob, PWideChar(WideString('UDAW secret')),
       @entBlob, nil, nil, 0, @outBlob) then
    RaiseUDAWFmt(errSecureStorage, SUBSYS,
      'CryptProtectData failed (error %d)', [GetLastError]);
  try
    SetLength(protectedBytes, outBlob.cbData);
    if outBlob.cbData > 0 then
      Move(outBlob.pbData^, protectedBytes[0], outBlob.cbData);
  finally
    if outBlob.pbData <> nil then
      LocalFree(HLOCAL(outBlob.pbData));
  end;

  FList.Values[AKey] := Base64Encode(protectedBytes);
  SaveAtomic;
end;

function TWindowsDPAPIStore.GetSecret(const AKey: string; out AValue: string): Boolean;
var
  stored: string;
  inBlob, outBlob, entBlob: DATA_BLOB;
  cipher, ent, plain: TBytes;
begin
  AValue := '';
  stored := FList.Values[AKey];
  if stored = '' then
    Exit(False);

  cipher := Base64Decode(stored);
  ent := Entropy(AKey);
  if Length(cipher) = 0 then
    Exit(False);

  FillChar(inBlob, SizeOf(inBlob), 0);
  FillChar(outBlob, SizeOf(outBlob), 0);
  FillChar(entBlob, SizeOf(entBlob), 0);
  inBlob.cbData := Length(cipher);
  inBlob.pbData := @cipher[0];
  entBlob.cbData := Length(ent);
  entBlob.pbData := @ent[0];

  if not CryptUnprotectData(@inBlob, nil, @entBlob, nil, nil, 0, @outBlob) then
    RaiseUDAWFmt(errSecureStorage, SUBSYS,
      'CryptUnprotectData failed for "%s" (error %d)', [AKey, GetLastError]);
  try
    SetLength(plain, outBlob.cbData);
    if outBlob.cbData > 0 then
      Move(outBlob.pbData^, plain[0], outBlob.cbData);
  finally
    if outBlob.pbData <> nil then
      LocalFree(HLOCAL(outBlob.pbData));
  end;

  AValue := TEncoding.UTF8.GetString(plain);
  Result := True;
end;

function TWindowsDPAPIStore.HasSecret(const AKey: string): Boolean;
begin
  Result := FList.IndexOfName(AKey) >= 0;
end;

procedure TWindowsDPAPIStore.DeleteSecret(const AKey: string);
var
  idx: Integer;
begin
  idx := FList.IndexOfName(AKey);
  if idx >= 0 then
  begin
    FList.Delete(idx);
    SaveAtomic;
  end;
end;
{$ENDIF MSWINDOWS}

{ ================= POSIX helper: run a child process ================= }

{$IF DEFINED(UDAW_MACOS) OR DEFINED(UDAW_POSIX)}
function RunCapture(const AExe: string; const AArgs: array of string;
  const AStdin: string; out AStdOut, AStdErr: string): Integer;
var
  p: TProcess;
  i: Integer;
  outStream, errStream: TStringStream;
  buf: array[0..4095] of Byte;
  n: LongInt;
  running: Boolean;
begin
  AStdOut := '';
  AStdErr := '';
  p := TProcess.Create(nil);
  outStream := TStringStream.Create('');
  errStream := TStringStream.Create('');
  try
    p.Executable := AExe;
    for i := Low(AArgs) to High(AArgs) do
      p.Parameters.Add(AArgs[i]);
    p.Options := [poUsePipes, poNoConsole];
    p.Execute;

    if AStdin <> '' then
      p.Input.Write(AStdin[1], Length(AStdin));
    p.CloseInput;

    repeat
      running := p.Running;
      n := p.Output.NumBytesAvailable;
      while n > 0 do
      begin
        if n > SizeOf(buf) then n := SizeOf(buf);
        n := p.Output.Read(buf, n);
        if n > 0 then outStream.Write(buf, n);
        n := p.Output.NumBytesAvailable;
      end;
      n := p.Stderr.NumBytesAvailable;
      while n > 0 do
      begin
        if n > SizeOf(buf) then n := SizeOf(buf);
        n := p.Stderr.Read(buf, n);
        if n > 0 then errStream.Write(buf, n);
        n := p.Stderr.NumBytesAvailable;
      end;
      if running then
        Sleep(5);
    until not running;

    AStdOut := outStream.DataString;
    AStdErr := errStream.DataString;
    Result := p.ExitStatus;
  finally
    outStream.Free;
    errStream.Free;
    p.Free;
  end;
end;

function WhichExe(const AName: string): string;
var
  pathVar, dir: string;
  parts: TStringList;
  i: Integer;
begin
  Result := '';
  pathVar := GetEnvironmentVariable('PATH');
  parts := TStringList.Create;
  try
    parts.Delimiter := ':';
    parts.StrictDelimiter := True;
    parts.DelimitedText := pathVar;
    for i := 0 to parts.Count - 1 do
    begin
      dir := parts[i];
      if dir = '' then Continue;
      dir := IncludeTrailingPathDelimiter(dir) + AName;
      if FileExists(dir) then
        Exit(dir);
    end;
  finally
    parts.Free;
  end;
end;
{$IFEND}

{ ================= macOS: /usr/bin/security ================= }

{$IFDEF UDAW_MACOS}
type
  TMacKeychainStore = class(TInterfacedObject, ISecureStore)
  public
    function ProviderName: string;
    function IsAvailable: Boolean;
    procedure SetSecret(const AKey, AValue: string);
    function GetSecret(const AKey: string; out AValue: string): Boolean;
    function HasSecret(const AKey: string): Boolean;
    procedure DeleteSecret(const AKey: string);
  end;

const
  SECURITY_BIN = '/usr/bin/security';

function TMacKeychainStore.ProviderName: string;
begin
  Result := 'macOS Keychain';
end;

function TMacKeychainStore.IsAvailable: Boolean;
begin
  Result := FileExists(SECURITY_BIN);
end;

procedure TMacKeychainStore.SetSecret(const AKey, AValue: string);
var
  so, se: string;
  rc: Integer;
begin
  if not IsAvailable then
    RaiseUDAW(errSecureStorage, SUBSYS, 'macOS "security" tool not found');
  rc := RunCapture(SECURITY_BIN,
    ['add-generic-password', '-a', AKey, '-s', SECRET_SERVICE,
     '-D', 'UDAW secret', '-w', AValue, '-U'], '', so, se);
  if rc <> 0 then
    RaiseUDAWFmt(errSecureStorage, SUBSYS, 'security add-generic-password failed: %s', [se]);
end;

function TMacKeychainStore.GetSecret(const AKey: string; out AValue: string): Boolean;
var
  so, se: string;
  rc: Integer;
begin
  AValue := '';
  if not IsAvailable then
    RaiseUDAW(errSecureStorage, SUBSYS, 'macOS "security" tool not found');
  rc := RunCapture(SECURITY_BIN,
    ['find-generic-password', '-a', AKey, '-s', SECRET_SERVICE, '-w'], '', so, se);
  if rc <> 0 then
    Exit(False);
  AValue := TrimRight(so);   // security appends a newline
  Result := True;
end;

function TMacKeychainStore.HasSecret(const AKey: string): Boolean;
var
  dummy: string;
begin
  Result := GetSecret(AKey, dummy);
end;

procedure TMacKeychainStore.DeleteSecret(const AKey: string);
var
  so, se: string;
begin
  if not IsAvailable then
    RaiseUDAW(errSecureStorage, SUBSYS, 'macOS "security" tool not found');
  RunCapture(SECURITY_BIN,
    ['delete-generic-password', '-a', AKey, '-s', SECRET_SERVICE], '', so, se);
end;
{$ENDIF UDAW_MACOS}

{ ================= Linux/BSD: secret-tool (libsecret) ================= }

{$IF DEFINED(UDAW_POSIX) AND NOT DEFINED(UDAW_MACOS)}
type
  TSecretToolStore = class(TInterfacedObject, ISecureStore)
  private
    FExe: string;
    procedure NeedTool;
  public
    constructor Create;
    function ProviderName: string;
    function IsAvailable: Boolean;
    procedure SetSecret(const AKey, AValue: string);
    function GetSecret(const AKey: string; out AValue: string): Boolean;
    function HasSecret(const AKey: string): Boolean;
    procedure DeleteSecret(const AKey: string);
  end;

constructor TSecretToolStore.Create;
begin
  inherited Create;
  FExe := WhichExe('secret-tool');
end;

function TSecretToolStore.ProviderName: string;
begin
  Result := 'Linux Secret Service (secret-tool)';
end;

function TSecretToolStore.IsAvailable: Boolean;
begin
  Result := FExe <> '';
end;

procedure TSecretToolStore.NeedTool;
begin
  if not IsAvailable then
    RaiseUDAW(errSecureStorage, SUBSYS,
      '"secret-tool" not found. Install libsecret-tools (Debian/Ubuntu) or ' +
      'libsecret (Fedora/Arch) to store UDAW credentials securely.');
end;

procedure TSecretToolStore.SetSecret(const AKey, AValue: string);
var
  so, se: string;
  rc: Integer;
begin
  NeedTool;
  rc := RunCapture(FExe,
    ['store', '--label=UDAW ' + AKey, 'service', SECRET_SERVICE, 'account', AKey],
    AValue, so, se);
  if rc <> 0 then
    RaiseUDAWFmt(errSecureStorage, SUBSYS, 'secret-tool store failed: %s', [se]);
end;

function TSecretToolStore.GetSecret(const AKey: string; out AValue: string): Boolean;
var
  so, se: string;
  rc: Integer;
begin
  AValue := '';
  NeedTool;
  rc := RunCapture(FExe,
    ['lookup', 'service', SECRET_SERVICE, 'account', AKey], '', so, se);
  if rc <> 0 then
    Exit(False);
  AValue := TrimRight(so);
  Result := True;
end;

function TSecretToolStore.HasSecret(const AKey: string): Boolean;
var
  dummy: string;
begin
  Result := GetSecret(AKey, dummy);
end;

procedure TSecretToolStore.DeleteSecret(const AKey: string);
var
  so, se: string;
begin
  NeedTool;
  RunCapture(FExe, ['clear', 'service', SECRET_SERVICE, 'account', AKey], '', so, se);
end;
{$IFEND}

{ ================= factory ================= }

var
  GStore: ISecureStore;

function SecureStore: ISecureStore;
begin
  if GStore = nil then
  begin
    {$IF DEFINED(MSWINDOWS)}
    GStore := TWindowsDPAPIStore.Create;
    {$ELSEIF DEFINED(UDAW_MACOS)}
    GStore := TMacKeychainStore.Create;
    {$ELSEIF DEFINED(UDAW_POSIX)}
    GStore := TSecretToolStore.Create;
    {$ELSE}
    RaiseUDAW(errPlatform, SUBSYS, 'No secure storage provider for this platform');
    {$IFEND}
  end;
  Result := GStore;
end;

initialization

finalization
  GStore := nil;

end.
