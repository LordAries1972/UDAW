unit UDAW.AI.HTTP;
{$I udaw.inc}

{ Phase 20 - synchronous HTTP client for AI provider REST calls (Phases
  21-23) and the MCP HTTP+SSE transport (UDAW.AI.MCP). Built on the RTL's
  own HTTP client (System.Net.HttpClient on Delphi, fphttpclient on FPC) -
  not a third-party library, just the platform's standard networking unit.

  GetBytes (Phase 24) is the binary counterpart to Get/Post: Suno's
  generation API hands back a URL to an MP3, and a UTF-8 string round-trip
  through TAIHttpResponse.Body would corrupt those bytes.

  All requests/responses are logged (method + URL + body LENGTH only, never
  header or body content) through UDAW.AI.SecureLog so a raw Authorization
  or API-key header can never reach a log file even by accident. }

interface

uses
  SysUtils, Classes, SyncObjs,
  UDAW.Errors, UDAW.AI.SecureLog
  {$IFDEF FPC}
  , fphttpclient, opensslsockets
  {$ELSE}
  , System.Net.HttpClient, System.Net.URLClient
  {$ENDIF}
  ;

type
  { Thread-safe cooperative cancellation flag. A long-running HTTP call polls
    IsCancelled between reads and aborts (raising errCancelled) when set. }
  TAICancelToken = class
  private
    FLock: TCriticalSection;
    FCancelled: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Cancel;
    function IsCancelled: Boolean;
  end;

  TAIHttpHeader = record
    Name: string;
    Value: string;
  end;

  TAIHttpResponse = record
    StatusCode: Integer;
    Body: string;
  end;

  { Method-pointer event, not an anonymous-method closure, matching this
    codebase's `of object` event convention for broadest Delphi/FPC
    compatibility. Invoked once per complete line of a streamed response. }
  TAIStreamLineProc = procedure(const ALine: string) of object;

  TAIHttpClient = class
  private
    FTimeoutMs: Integer;
    procedure CheckCancelledBeforeStart(ACancel: TAICancelToken; const ASubsys: string);
    procedure LogRequest(const AMethod, AUrl: string; ABodyLen: Integer);
    procedure LogResponse(const AMethod, AUrl: string; AStatusCode, ABodyLen: Integer);
  public
    constructor Create;
    destructor Destroy; override;

    procedure Configure(ATimeoutMs: Integer = 30000);

    function Post(const AUrl: string; const AHeaders: array of TAIHttpHeader;
      const ABody: string; ACancel: TAICancelToken = nil): TAIHttpResponse;
    function Get(const AUrl: string; const AHeaders: array of TAIHttpHeader;
      ACancel: TAICancelToken = nil): TAIHttpResponse;

    { Binary GET - for downloading generated media (Phase 24 - Suno audio
      results) where a UTF-8 string round-trip would corrupt the bytes. }
    function GetBytes(const AUrl: string; const AHeaders: array of TAIHttpHeader;
      out AStatusCode: Integer; ACancel: TAICancelToken = nil): TBytes;

    { Server-Sent-Events-shaped streaming POST (the pattern OpenAI / Claude /
      DeepSeek streaming chat completions use). Invokes ALineCallback once
      per complete line as the response body is consumed.

      NOTE (documented fallback, per Phase 20 scope): true incremental
      delivery from the underlying RTL HTTP clients needs a concrete,
      testable provider to get exactly right end to end. For now this
      performs the request to completion and then replays ALineCallback once
      per line of the full body - functionally correct for a caller that
      only cares about "one callback per line", but not yet byte-incremental.
      Upgrading to genuine incremental delivery is a Phase 21+ hardening
      item once a real provider stream is available to test against. }
    function PostStreaming(const AUrl: string; const AHeaders: array of TAIHttpHeader;
      const ABody: string; ALineCallback: TAIStreamLineProc;
      ACancel: TAICancelToken = nil): TAIHttpResponse;
  end;

implementation

const
  SUBSYS = 'AI.HTTP';

{ ---------------- TAICancelToken ---------------- }

constructor TAICancelToken.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FCancelled := False;
end;

destructor TAICancelToken.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TAICancelToken.Cancel;
begin
  FLock.Enter;
  try
    FCancelled := True;
  finally
    FLock.Leave;
  end;
end;

function TAICancelToken.IsCancelled: Boolean;
begin
  FLock.Enter;
  try
    Result := FCancelled;
  finally
    FLock.Leave;
  end;
end;

{ ---------------- TAIHttpClient ---------------- }

constructor TAIHttpClient.Create;
begin
  inherited Create;
  FTimeoutMs := 30000;
end;

destructor TAIHttpClient.Destroy;
begin
  inherited Destroy;
end;

procedure TAIHttpClient.Configure(ATimeoutMs: Integer = 30000);
begin
  if ATimeoutMs <= 0 then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'timeout must be positive');
  FTimeoutMs := ATimeoutMs;
end;

procedure TAIHttpClient.CheckCancelledBeforeStart(ACancel: TAICancelToken; const ASubsys: string);
begin
  if (ACancel <> nil) and ACancel.IsCancelled then
    RaiseUDAW(errCancelled, ASubsys, 'request cancelled');
end;

procedure TAIHttpClient.LogRequest(const AMethod, AUrl: string; ABodyLen: Integer);
begin
  AISecureLog.Info(SUBSYS, Format('%s %s (body %d bytes)', [AMethod, AUrl, ABodyLen]));
end;

procedure TAIHttpClient.LogResponse(const AMethod, AUrl: string; AStatusCode, ABodyLen: Integer);
begin
  AISecureLog.Info(SUBSYS, Format('%s %s -> %d (%d bytes)', [AMethod, AUrl, AStatusCode, ABodyLen]));
end;

{$IFDEF FPC}

function TAIHttpClient.Post(const AUrl: string; const AHeaders: array of TAIHttpHeader;
  const ABody: string; ACancel: TAICancelToken = nil): TAIHttpResponse;
var
  client: TFPHTTPClient;
  reqStream, respStream: TStringStream;
  i: Integer;
begin
  CheckCancelledBeforeStart(ACancel, SUBSYS);
  LogRequest('POST', AUrl, Length(ABody));
  client := TFPHTTPClient.Create(nil);
  reqStream := TStringStream.Create(ABody, TEncoding.UTF8);
  respStream := TStringStream.Create('');
  try
    client.IOTimeout := FTimeoutMs;
    for i := Low(AHeaders) to High(AHeaders) do
      client.AddHeader(AHeaders[i].Name, AHeaders[i].Value);
    client.RequestBody := reqStream;
    try
      client.Post(AUrl, respStream);
    except
      on E: Exception do
        RaiseUDAWFmt(errNetwork, SUBSYS, 'POST %s failed: %s', [AUrl, E.Message]);
    end;
    Result.StatusCode := client.ResponseStatusCode;
    Result.Body := respStream.DataString;
    LogResponse('POST', AUrl, Result.StatusCode, Length(Result.Body));
  finally
    client.Free;
    reqStream.Free;
    respStream.Free;
  end;
end;

function TAIHttpClient.Get(const AUrl: string; const AHeaders: array of TAIHttpHeader;
  ACancel: TAICancelToken = nil): TAIHttpResponse;
var
  client: TFPHTTPClient;
  respStream: TStringStream;
  i: Integer;
begin
  CheckCancelledBeforeStart(ACancel, SUBSYS);
  LogRequest('GET', AUrl, 0);
  client := TFPHTTPClient.Create(nil);
  respStream := TStringStream.Create('');
  try
    client.IOTimeout := FTimeoutMs;
    for i := Low(AHeaders) to High(AHeaders) do
      client.AddHeader(AHeaders[i].Name, AHeaders[i].Value);
    try
      client.Get(AUrl, respStream);
    except
      on E: Exception do
        RaiseUDAWFmt(errNetwork, SUBSYS, 'GET %s failed: %s', [AUrl, E.Message]);
    end;
    Result.StatusCode := client.ResponseStatusCode;
    Result.Body := respStream.DataString;
    LogResponse('GET', AUrl, Result.StatusCode, Length(Result.Body));
  finally
    client.Free;
    respStream.Free;
  end;
end;

function TAIHttpClient.GetBytes(const AUrl: string; const AHeaders: array of TAIHttpHeader;
  out AStatusCode: Integer; ACancel: TAICancelToken = nil): TBytes;
var
  client: TFPHTTPClient;
  respStream: TMemoryStream;
  i: Integer;
begin
  CheckCancelledBeforeStart(ACancel, SUBSYS);
  LogRequest('GET', AUrl, 0);
  client := TFPHTTPClient.Create(nil);
  respStream := TMemoryStream.Create;
  try
    client.IOTimeout := FTimeoutMs;
    for i := Low(AHeaders) to High(AHeaders) do
      client.AddHeader(AHeaders[i].Name, AHeaders[i].Value);
    try
      client.Get(AUrl, respStream);
    except
      on E: Exception do
        RaiseUDAWFmt(errNetwork, SUBSYS, 'GET %s failed: %s', [AUrl, E.Message]);
    end;
    AStatusCode := client.ResponseStatusCode;
    SetLength(Result, respStream.Size);
    if respStream.Size > 0 then
    begin
      respStream.Position := 0;
      respStream.ReadBuffer(Result[0], respStream.Size);
    end;
    LogResponse('GET', AUrl, AStatusCode, Length(Result));
  finally
    client.Free;
    respStream.Free;
  end;
end;

{$ELSE}

function TAIHttpClient.Post(const AUrl: string; const AHeaders: array of TAIHttpHeader;
  const ABody: string; ACancel: TAICancelToken = nil): TAIHttpResponse;
var
  client: THTTPClient;
  headers: TNetHeaders;
  i: Integer;
  reqStream: TStringStream;
  resp: IHTTPResponse;
begin
  CheckCancelledBeforeStart(ACancel, SUBSYS);
  LogRequest('POST', AUrl, Length(ABody));
  client := THTTPClient.Create;
  reqStream := TStringStream.Create(ABody, TEncoding.UTF8);
  try
    client.ConnectionTimeout := FTimeoutMs;
    client.ResponseTimeout := FTimeoutMs;
    SetLength(headers, Length(AHeaders));
    for i := Low(AHeaders) to High(AHeaders) do
      headers[i] := TNameValuePair.Create(AHeaders[i].Name, AHeaders[i].Value);
    try
      resp := client.Post(AUrl, reqStream, nil, headers);
    except
      on E: Exception do
        RaiseUDAWFmt(errNetwork, SUBSYS, 'POST %s failed: %s', [AUrl, E.Message]);
    end;
    Result.StatusCode := resp.StatusCode;
    Result.Body := resp.ContentAsString(TEncoding.UTF8);
    LogResponse('POST', AUrl, Result.StatusCode, Length(Result.Body));
  finally
    reqStream.Free;
    client.Free;
  end;
end;

function TAIHttpClient.Get(const AUrl: string; const AHeaders: array of TAIHttpHeader;
  ACancel: TAICancelToken = nil): TAIHttpResponse;
var
  client: THTTPClient;
  headers: TNetHeaders;
  i: Integer;
  resp: IHTTPResponse;
begin
  CheckCancelledBeforeStart(ACancel, SUBSYS);
  LogRequest('GET', AUrl, 0);
  client := THTTPClient.Create;
  try
    client.ConnectionTimeout := FTimeoutMs;
    client.ResponseTimeout := FTimeoutMs;
    SetLength(headers, Length(AHeaders));
    for i := Low(AHeaders) to High(AHeaders) do
      headers[i] := TNameValuePair.Create(AHeaders[i].Name, AHeaders[i].Value);
    try
      resp := client.Get(AUrl, nil, headers);
    except
      on E: Exception do
        RaiseUDAWFmt(errNetwork, SUBSYS, 'GET %s failed: %s', [AUrl, E.Message]);
    end;
    Result.StatusCode := resp.StatusCode;
    Result.Body := resp.ContentAsString(TEncoding.UTF8);
    LogResponse('GET', AUrl, Result.StatusCode, Length(Result.Body));
  finally
    client.Free;
  end;
end;

function TAIHttpClient.GetBytes(const AUrl: string; const AHeaders: array of TAIHttpHeader;
  out AStatusCode: Integer; ACancel: TAICancelToken = nil): TBytes;
var
  client: THTTPClient;
  headers: TNetHeaders;
  i: Integer;
  resp: IHTTPResponse;
  ms: TMemoryStream;
begin
  CheckCancelledBeforeStart(ACancel, SUBSYS);
  LogRequest('GET', AUrl, 0);
  client := THTTPClient.Create;
  ms := TMemoryStream.Create;
  try
    client.ConnectionTimeout := FTimeoutMs;
    client.ResponseTimeout := FTimeoutMs;
    SetLength(headers, Length(AHeaders));
    for i := Low(AHeaders) to High(AHeaders) do
      headers[i] := TNameValuePair.Create(AHeaders[i].Name, AHeaders[i].Value);
    try
      resp := client.Get(AUrl, ms, headers);
    except
      on E: Exception do
        RaiseUDAWFmt(errNetwork, SUBSYS, 'GET %s failed: %s', [AUrl, E.Message]);
    end;
    AStatusCode := resp.StatusCode;
    SetLength(Result, ms.Size);
    if ms.Size > 0 then
    begin
      ms.Position := 0;
      ms.ReadBuffer(Result[0], ms.Size);
    end;
    LogResponse('GET', AUrl, AStatusCode, Length(Result));
  finally
    ms.Free;
    client.Free;
  end;
end;

{$ENDIF}

function TAIHttpClient.PostStreaming(const AUrl: string; const AHeaders: array of TAIHttpHeader;
  const ABody: string; ALineCallback: TAIStreamLineProc;
  ACancel: TAICancelToken = nil): TAIHttpResponse;
var
  lines: TStringList;
  i: Integer;
  line: string;
begin
  CheckCancelledBeforeStart(ACancel, SUBSYS);
  { See the NOTE on the interface declaration: this performs the POST to
    completion, then replays one callback per line of the full body. }
  Result := Post(AUrl, AHeaders, ABody, ACancel);

  lines := TStringList.Create;
  try
    lines.Text := Result.Body;
    for i := 0 to lines.Count - 1 do
    begin
      if (ACancel <> nil) and ACancel.IsCancelled then
        RaiseUDAW(errCancelled, SUBSYS, 'request cancelled');
      line := lines[i];
      if (Length(line) > 0) and (line[Length(line)] = #13) then
        line := Copy(line, 1, Length(line) - 1);
      if Assigned(ALineCallback) then
        ALineCallback(line);
    end;
  finally
    lines.Free;
  end;
end;

end.
