unit UDAW.AI.MCPDiag;
{$I udaw.inc}

{ Connectivity self-test for an MCP endpoint - local (http://127.0.0.1:port/mcp)
  or remote (https://host:port/mcp). It walks the same path a remote AI agent
  takes and reports each stage, so a failure says WHERE it broke (DNS/TCP, TLS
  handshake or certificate, authentication, MCP handshake, tool discovery):

    1. URL parsed
    2. MCP "initialize" round trip (TCP connect + TLS handshake for https)
    3. TLS details: protocol version, cipher, certificate subject / expiry
    4. "tools/list" - tools advertised
    5. Auth enforcement: the same request WITHOUT the token must be refused
       (only when a token is supplied) - proves the endpoint is not open.

  Uses Indy + TaurusTLS (OpenSSL) so it can also report certificate details and,
  for testing a self-signed certificate, skip chain verification on request.
  Delphi-only. Safe to call on a worker thread; it never touches the UI. }

interface

uses
  SysUtils, Classes;

type
  TMCPDiagResult = record
    Ok: Boolean;                // every stage that applies passed
    Reachable: Boolean;         // an MCP initialize reply was received
    IsTls: Boolean;
    ToolCount: Integer;
    Report: string;             // multi-line, human readable
  end;

{ AUrl: full endpoint URL. AToken: bearer token ('' = none). AAllowSelfSigned:
  skip certificate-chain verification (test/self-signed certificates only). }
function MCPTestEndpoint(const AUrl, AToken: string; AAllowSelfSigned: Boolean;
  ATimeoutMs: Integer = 10000): TMCPDiagResult;

implementation

{$IFNDEF FPC}
uses
  StrUtils, IdHTTP, IdURI, IdException, IdStack, TaurusTLS, TaurusTLS_X509, UDAW.AI.JSON;

const
  INIT_BODY = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":' +
    '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"UDAW-diag","version":"1"}}}';
  LIST_BODY = '{"jsonrpc":"2.0","id":2,"method":"tools/list"}';

type
  TDiag = class
  public
    Http: TIdHTTP;
    Ssl: TTaurusTLSIOHandlerSocket;
    Lines: TStringList;
    constructor Create(ATls, AAllowSelfSigned: Boolean; ATimeoutMs: Integer);
    destructor Destroy; override;
    { Returns HTTP status (0 = transport failure, text in AErr). }
    function Post(const AUrl, AToken, ABody: string; out AResp, AErr: string): Integer;
  end;

constructor TDiag.Create(ATls, AAllowSelfSigned: Boolean; ATimeoutMs: Integer);
begin
  inherited Create;
  Lines := TStringList.Create;
  Http := TIdHTTP.Create(nil);
  Http.ConnectTimeout := ATimeoutMs;
  Http.ReadTimeout := ATimeoutMs;
  Http.HandleRedirects := False;
  Http.Request.ContentType := 'application/json';
  Http.Request.Accept := 'application/json, text/event-stream';
  Http.Request.UserAgent := 'UDAW-MCP-diag';
  if ATls then
  begin
    Ssl := TTaurusTLSIOHandlerSocket.Create(nil);
    Ssl.SSLOptions.MinTLSVersion := TLSv1_2;
    if AAllowSelfSigned then
      Ssl.SSLOptions.VerifyMode := []
    else
    begin
      Ssl.SSLOptions.VerifyMode := [sslvrfPeer];
      Ssl.SSLOptions.VerifyDepth := 9;
    end;
    Http.IOHandler := Ssl;
  end;
end;

destructor TDiag.Destroy;
begin
  Http.IOHandler := nil;
  Ssl.Free;
  Http.Free;
  Lines.Free;
  inherited Destroy;
end;

function TDiag.Post(const AUrl, AToken, ABody: string; out AResp, AErr: string): Integer;
var
  src: TStringStream;
begin
  AResp := '';
  AErr := '';
  Http.Request.CustomHeaders.Clear;
  Http.Request.CustomHeaders.Values['MCP-Protocol-Version'] := '2025-06-18';
  if AToken <> '' then
    Http.Request.CustomHeaders.Values['Authorization'] := 'Bearer ' + AToken;
  src := TStringStream.Create(ABody, TEncoding.UTF8);
  try
    try
      AResp := Http.Post(AUrl, src);
      Result := Http.ResponseCode;
    except
      on E: EIdHTTPProtocolException do
      begin
        Result := Http.ResponseCode;
        AResp := E.ErrorMessage;
      end;
      on E: Exception do
      begin
        Result := 0;
        AErr := E.ClassName + ': ' + E.Message;
      end;
    end;
  finally
    src.Free;
  end;
end;

function MCPTestEndpoint(const AUrl, AToken: string; AAllowSelfSigned: Boolean;
  ATimeoutMs: Integer): TMCPDiagResult;
var
  uri: TIdURI;
  d: TDiag;
  code: Integer;
  resp, err, payload: string;
  json, res, tools: TJSONValue;
  hint, proto: string;

  procedure Say(const S: string);
  begin
    d.Lines.Add(S);
  end;

begin
  Result.Ok := False;
  Result.Reachable := False;
  Result.IsTls := False;
  Result.ToolCount := 0;
  Result.Report := '';

  uri := TIdURI.Create(Trim(AUrl));
  try
    Result.IsTls := SameText(uri.Protocol, 'https');
    if not (SameText(uri.Protocol, 'http') or SameText(uri.Protocol, 'https')) or (uri.Host = '') then
    begin
      Result.Report := 'FAIL  URL: "' + AUrl + '" is not a valid http:// or https:// endpoint.';
      Exit;
    end;
  finally
    uri.Free;
  end;

  d := TDiag.Create(Result.IsTls, AAllowSelfSigned, ATimeoutMs);
  try
    Say('Endpoint: ' + Trim(AUrl));
    Say(Format('Mode: %s%s', [IfThen(Result.IsTls, 'HTTPS (TLS 1.2+)', 'plain HTTP'),
      IfThen(Result.IsTls and AAllowSelfSigned, ', certificate NOT verified (self-signed allowed)', '')]));

    { --- 2. initialize --- }
    code := d.Post(Trim(AUrl), AToken, INIT_BODY, resp, err);
    if code = 0 then
    begin
      hint := '';
      if Pos('certificate', LowerCase(err)) > 0 then
        hint := ' (TLS certificate not trusted - use a CA-signed certificate, or tick "allow self-signed" for a test cert)'
      else if Pos('refused', LowerCase(err)) > 0 then
        hint := ' (nothing is listening there - check the port, firewall / port-forward / tunnel)'
      else if (Pos('timed out', LowerCase(err)) > 0) or (Pos('timeout', LowerCase(err)) > 0) then
        hint := ' (no reply - firewall or router is dropping the traffic)';
      Say('FAIL  connect/TLS: ' + err + hint);
      Result.Report := Trim(d.Lines.Text);
      Exit;
    end;
    if code = 401 then
    begin
      Say('FAIL  auth: HTTP 401 - the server rejected the bearer token (wrong/missing token).');
      Result.Reachable := True;
      Result.Report := Trim(d.Lines.Text);
      Exit;
    end;
    if (code < 200) or (code >= 300) then
    begin
      Say(Format('FAIL  initialize: HTTP %d', [code]));
      Result.Report := Trim(d.Lines.Text);
      Exit;
    end;
    payload := Trim(resp);
    if (payload <> '') and (payload[1] <> '{') then
    begin
      { SSE-wrapped reply: take the data: line }
      payload := Trim(Copy(payload, Pos('data:', payload) + 5, MaxInt));
      if Pos(#10, payload) > 0 then payload := Trim(Copy(payload, 1, Pos(#10, payload) - 1));
    end;
    try
      json := UDAW.AI.JSON.Parse(payload);
    except
      json := nil;
    end;
    if (json = nil) or (json.ByName('result') = nil) then
    begin
      Say('FAIL  initialize: HTTP 200 but the reply is not a JSON-RPC result - this URL is not an MCP endpoint.');
      json.Free;
      Result.Report := Trim(d.Lines.Text);
      Exit;
    end;
    res := json.ByName('result');
    Result.Reachable := True;
    proto := '?';
    if res.ByName('protocolVersion') <> nil then proto := res.ByName('protocolVersion').AsString;
    Say(Format('PASS  initialize: HTTP %d, protocol %s', [code, proto]));
    json.Free;

    { --- 3. TLS details --- }
    if Result.IsTls and (d.Ssl <> nil) and (d.Ssl.SSLSocket <> nil) then
    try
      Say('PASS  TLS: ' + d.Ssl.SSLSocket.SSLProtocolVersionStr +
        ', cipher ' + d.Ssl.SSLSocket.Cipher.Name);
      if d.Ssl.SSLSocket.PeerCert <> nil then
        Say(Format('      certificate: %s, valid until %s',
          [d.Ssl.SSLSocket.PeerCert.Subject.OneLine,
           FormatDateTime('yyyy-mm-dd', d.Ssl.SSLSocket.PeerCert.notAfter)]));
    except
      on E: Exception do Say('INFO  TLS details unavailable: ' + E.Message);
    end;

    { --- 4. tools/list --- }
    code := d.Post(Trim(AUrl), AToken, LIST_BODY, resp, err);
    if (code >= 200) and (code < 300) then
    begin
      payload := Trim(resp);
      if (payload <> '') and (payload[1] <> '{') then
        payload := Trim(Copy(payload, Pos('data:', payload) + 5, MaxInt));
      try
        json := UDAW.AI.JSON.Parse(payload);
        try
          tools := nil;
          if json.ByName('result') <> nil then tools := json.ByName('result').ByName('tools');
          if (tools <> nil) and (tools.Kind = jkArray) then
          begin
            Result.ToolCount := tools.Count;
            Say(Format('PASS  tools/list: %d tool(s) advertised', [tools.Count]));
          end
          else
            Say('FAIL  tools/list: reply has no tools array');
        finally
          json.Free;
        end;
      except
        on E: Exception do Say('FAIL  tools/list: ' + E.Message);
      end;
    end
    else
      Say(Format('FAIL  tools/list: HTTP %d %s', [code, err]));

    { --- 5. auth enforcement --- }
    if AToken <> '' then
    begin
      code := d.Post(Trim(AUrl), '', LIST_BODY, resp, err);
      if code = 401 then
        Say('PASS  auth enforced: a request without the token is refused (HTTP 401)')
      else if code = 0 then
        Say('INFO  auth check skipped (connection closed on the tokenless request - also acceptable)')
      else
        Say(Format('WARN  auth NOT enforced: a tokenless request got HTTP %d - the endpoint is open!', [code]));
    end
    else
      Say('INFO  no token supplied - cannot test authentication (a remote endpoint should always have one)');

    Result.Ok := Result.Reachable and (Result.ToolCount > 0) and (Pos('FAIL', d.Lines.Text) = 0)
      and (Pos('WARN', d.Lines.Text) = 0);
    if Result.Ok then Say('RESULT: connection OK') else Say('RESULT: connection has problems (see above)');
    Result.Report := Trim(d.Lines.Text);
  finally
    d.Free;
  end;
end;

{$ELSE}

function MCPTestEndpoint(const AUrl, AToken: string; AAllowSelfSigned: Boolean;
  ATimeoutMs: Integer): TMCPDiagResult;
begin
  Result.Ok := False;
  Result.Reachable := False;
  Result.IsTls := False;
  Result.ToolCount := 0;
  Result.Report := 'The MCP connectivity test is only implemented on Delphi today.';
end;

{$ENDIF}

end.
