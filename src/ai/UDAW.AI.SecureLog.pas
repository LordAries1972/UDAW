unit UDAW.AI.SecureLog;
{$I udaw.inc}

{ Phase 20 - a redacting log wrapper so API keys / bearer tokens never land
  in a plaintext log file or the in-memory log sink. Every message routed
  through TAISecureLog is passed through Redact() before it reaches the
  process-wide UDAW.Logging.Logger.

  Redact() does two things:
    1. Scrubs every literal secret previously handed to RegisterSecret
       (e.g. a live API key the credentials/HTTP units just used).
    2. Defensively masks common secret-shaped substrings even when they were
       never registered - "Bearer <token>", and a run of 20+ token chars
       right after "sk-", "key=", "api_key=" or "Authorization:"
       (case-insensitive). This is deliberately simple substring/char
       scanning, not a regex engine, matching the shapes those specific
       prefixes actually produce. }

interface

uses
  SysUtils, Classes, SyncObjs, UDAW.Logging;

type
  TAISecureLog = class
  private
    FLock: TCriticalSection;
    FSecrets: TStringList;
    function MaskAfterPrefix(const AText, APrefixUpper: string): string;
    function MaskBearer(const AText: string): string;
  public
    constructor Create;
    destructor Destroy; override;

    procedure RegisterSecret(const AValue: string);
    function Redact(const AText: string): string;

    procedure Info(const ASubsystem, AText: string);
    procedure Warn(const ASubsystem, AText: string);
    procedure Error(const ASubsystem, AText: string);
    procedure Debug(const ASubsystem, AText: string);
  end;

function AISecureLog: TAISecureLog;

implementation

const
  MASK = '****';
  TOKEN_CHARS: set of AnsiChar = ['A'..'Z', 'a'..'z', '0'..'9', '-', '_'];

constructor TAISecureLog.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FSecrets := TStringList.Create;
  FSecrets.Duplicates := dupIgnore;
  FSecrets.Sorted := True;
end;

destructor TAISecureLog.Destroy;
begin
  FSecrets.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TAISecureLog.RegisterSecret(const AValue: string);
begin
  if Trim(AValue) = '' then
    Exit;
  FLock.Enter;
  try
    if FSecrets.IndexOf(AValue) < 0 then
      FSecrets.Add(AValue);
  finally
    FLock.Leave;
  end;
end;

{ Replaces every run of TOKEN_CHARS immediately following APrefixUpper
  (matched case-insensitively) with MASK. Scans AText once left to right. }
function TAISecureLog.MaskAfterPrefix(const AText, APrefixUpper: string): string;
var
  sb: TStringBuilder;
  i, n, plen, j: Integer;
  upperText: string;
begin
  n := Length(AText);
  plen := Length(APrefixUpper);
  upperText := UpperCase(AText);
  sb := TStringBuilder.Create;
  try
    i := 1;
    while i <= n do
    begin
      if (plen > 0) and (i + plen - 1 <= n) and
         (Copy(upperText, i, plen) = APrefixUpper) then
      begin
        sb.Append(Copy(AText, i, plen));
        i := i + plen;
        j := i;
        while (j <= n) and CharInSet(AnsiChar(AText[j]), TOKEN_CHARS) do
          Inc(j);
        if (j - i) >= 20 then
        begin
          sb.Append(MASK);
          i := j;
        end;
      end
      else
      begin
        sb.Append(AText[i]);
        Inc(i);
      end;
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function TAISecureLog.MaskBearer(const AText: string): string;
var
  sb: TStringBuilder;
  i, n, j: Integer;
  upperText: string;
const
  PFX = 'BEARER ';
  PLEN = 7;
begin
  n := Length(AText);
  upperText := UpperCase(AText);
  sb := TStringBuilder.Create;
  try
    i := 1;
    while i <= n do
    begin
      if (i + PLEN - 1 <= n) and (Copy(upperText, i, PLEN) = PFX) then
      begin
        sb.Append('Bearer ');
        i := i + PLEN;
        j := i;
        while (j <= n) and (AText[j] <> ' ') and (AText[j] <> #9) and
              (AText[j] <> #10) and (AText[j] <> #13) do
          Inc(j);
        if j > i then
          sb.Append(MASK);
        i := j;
      end
      else
      begin
        sb.Append(AText[i]);
        Inc(i);
      end;
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function TAISecureLog.Redact(const AText: string): string;
var
  i: Integer;
  s: string;
begin
  s := AText;
  FLock.Enter;
  try
    for i := 0 to FSecrets.Count - 1 do
      if FSecrets[i] <> '' then
        s := StringReplace(s, FSecrets[i], MASK, [rfReplaceAll]);
  finally
    FLock.Leave;
  end;

  s := MaskBearer(s);
  s := MaskAfterPrefix(s, 'SK-');
  s := MaskAfterPrefix(s, 'KEY=');
  s := MaskAfterPrefix(s, 'API_KEY=');
  s := MaskAfterPrefix(s, 'AUTHORIZATION:');

  Result := s;
end;

procedure TAISecureLog.Info(const ASubsystem, AText: string);
begin
  Logger.Info(ASubsystem, Redact(AText));
end;

procedure TAISecureLog.Warn(const ASubsystem, AText: string);
begin
  Logger.Warn(ASubsystem, Redact(AText));
end;

procedure TAISecureLog.Error(const ASubsystem, AText: string);
begin
  Logger.Error(ASubsystem, Redact(AText));
end;

procedure TAISecureLog.Debug(const ASubsystem, AText: string);
begin
  Logger.Debug(ASubsystem, Redact(AText));
end;

var
  GAISecureLog: TAISecureLog;
  GAISecureLogLock: TCriticalSection;

function AISecureLog: TAISecureLog;
begin
  if GAISecureLog = nil then
  begin
    GAISecureLogLock.Enter;
    try
      if GAISecureLog = nil then
        GAISecureLog := TAISecureLog.Create;
    finally
      GAISecureLogLock.Leave;
    end;
  end;
  Result := GAISecureLog;
end;

initialization
  GAISecureLogLock := TCriticalSection.Create;

finalization
  FreeAndNil(GAISecureLog);
  FreeAndNil(GAISecureLogLock);

end.
