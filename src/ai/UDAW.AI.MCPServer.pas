unit UDAW.AI.MCPServer;
{$I udaw.inc}

{ Phase 26 - TUDAWMcpServer: the OTHER half of plan section 79 - optionally
  EXPOSING UDAW's own safe DAW command API (section 35 / UDAW.AI.ToolCommands)
  as an MCP server, so an external MCP-aware client (Claude Desktop, a local
  model, a future TLocalAIProvider) can drive the DAW through the exact same
  validated command path a built-in provider's tool call uses.

  Transport: a minimal HTTP/1.1 server (POST-only, one JSON-RPC request/
  response per connection, no keep-alive) built directly on the platform
  socket API - Winapi.Winsock2 on Windows, matching the "no third-party
  library" rule (Winsock2 is the OS API, not a vendored dependency) and the
  same from-scratch approach every other UDAW subsystem takes. This is
  deliberately not a general-purpose HTTP server: MCP-over-HTTP here is just
  "POST one JSON-RPC object, get one JSON-RPC object back", the same shape
  UDAW.AI.MCP's TMCPHttpTransport already speaks as a CLIENT.

  Safety, per the plan:
    * OFF by default; must be explicitly started.
    * Binds to loopback (127.0.0.1) unless the caller opts into a different
      bind address.
    * AllowDestructive is OFF by default - with it off, every destructive
      tool (see UDAW.AI.ToolCommands.IsDestructiveTool) is refused outright.
      With it on, a destructive call additionally requires the caller to
      pass "confirm": true in its arguments - a bare retry without that
      flag is refused again, so a client can't destructively mutate the
      project via one blind tool call.
    * Every call - destructive or not - is executed through the SAME
      TAIToolDispatcher / TCommandManager path the in-app AI chat panel
      uses, so it participates in Undo/Redo exactly like a mouse-driven
      edit and can never bypass a TDAWCommand's own validation.
    * A malformed request, an unknown method/tool, or any dispatcher
      exception is turned into a JSON-RPC error response - it never crashes
      the server thread or the host application.

  Only Windows is implemented today (this project's only verified target -
  see the platform-focus memory); Start raises errNotImplemented elsewhere,
  matching how macOS/Linux native audio backends are still open follow-up
  items rather than silently-broken stubs. }

interface

uses
  SysUtils, Classes, SyncObjs, Math, StrUtils,
  {$IF DEFINED(MSWINDOWS) AND NOT DEFINED(FPC)}
  Winapi.Winsock2,
  {$IFEND}
  UDAW.Errors, UDAW.AI.JSON, UDAW.AI.SecureLog,
  UDAW.AI.ToolCommands, UDAW.AI.MCPTls,
  UDAW.Project.Document, UDAW.Project.Commands;

type
  TMcpGetDocFunc = function: TProjectDocument of object;
  TMcpGetCommandsFunc = function: TCommandManager of object;
  TMcpGetBrowserRootsFunc = function: TArray<string> of object;

  TUDAWMcpServer = class
  private
    FBindAddress: string;
    FPort: Integer;
    FAllowDestructive: Boolean;
    FRunning: Boolean;
    FOnGetDoc: TMcpGetDocFunc;
    FOnGetCommands: TMcpGetCommandsFunc;
    FOnGetBrowserRoots: TMcpGetBrowserRootsFunc;
    FOnTransport: TAITransportFunc;
    FOnUICommand: TAIUICommandFunc;
    FAuthToken: string;
    FTlsPort: Integer;
    FTlsBindAddress: string;
    FTlsCertFile: string;
    FTlsKeyFile: string;
    FTlsKeyPassword: string;
    FTls: TMcpTlsListener;
    {$IF DEFINED(MSWINDOWS) AND NOT DEFINED(FPC)}
    FListenSocket: TSocket;
    FAcceptThread: TThread;
    FWsaStarted: Boolean;
    {$IFEND}
    function BuildToolsListJSON: string;
    function DispatchToolCall(const AToolId, AArgsJson: string; out AResultText: string): Boolean;
    function HandleJsonRpc(const ARequestBody: string): string;
    function BuildToolBlockJSON(const AToolId, AArgsJson: string): string;
  public
    constructor Create;
    destructor Destroy; override;

    property BindAddress: string read FBindAddress write FBindAddress;
    property Port: Integer read FPort write FPort;
    property AllowDestructive: Boolean read FAllowDestructive write FAllowDestructive;
    property OnGetDoc: TMcpGetDocFunc read FOnGetDoc write FOnGetDoc;
    property OnGetCommands: TMcpGetCommandsFunc read FOnGetCommands write FOnGetCommands;
    property OnGetBrowserRoots: TMcpGetBrowserRootsFunc read FOnGetBrowserRoots write FOnGetBrowserRoots;
    property OnTransport: TAITransportFunc read FOnTransport write FOnTransport;
    { menu / toolbar commands, selection, playhead and range: owned by the window }
    property OnUICommand: TAIUICommandFunc read FOnUICommand write FOnUICommand;
    { Bearer token every HTTP client must present ("Authorization: Bearer
      <token>"). Empty = no authentication, which Start only permits when
      bound to loopback. }
    property AuthToken: string read FAuthToken write FAuthToken;
    { HTTPS listener for remote agents (outside the LAN, via port-forward /
      reverse proxy / tunnel). TlsPort = 0 leaves it off. It REQUIRES AuthToken
      (a remotely reachable endpoint is never left open) and a PEM cert + key.
      It runs alongside the plain loopback listener, so local and TLS access
      are both available at once. }
    property TlsPort: Integer read FTlsPort write FTlsPort;
    property TlsBindAddress: string read FTlsBindAddress write FTlsBindAddress;
    property TlsCertFile: string read FTlsCertFile write FTlsCertFile;
    property TlsKeyFile: string read FTlsKeyFile write FTlsKeyFile;
    property TlsKeyPassword: string read FTlsKeyPassword write FTlsKeyPassword;
    function IsRunning: Boolean;
    function IsTlsRunning: Boolean;
    { Transport-neutral HTTP-level handling shared by the HTTPS listener:
      method check, bearer token, then JSON-RPC. Returns the body ('' for a
      notification) and the HTTP status. }
    function HandleHttpRequest(const AMethod, AAuthHeader, AOrigin, ABody: string;
      out AStatus: Integer): string;
    { True if AAuthorizationHeader satisfies AuthToken (constant-time compare). }
    function IsAuthorized(const AAuthorizationHeader: string): Boolean;
    { True if a request's Origin header is acceptable (loopback-only when the
      server is bound to loopback - DNS-rebinding guard). }
    function IsOriginAllowed(const AOrigin: string): Boolean;

    procedure Start;
    procedure Stop;

    { Exposed for unit testing the JSON-RPC dispatch without opening a real
      socket - HandleJsonRpc is pure request-text-in/response-text-out. }
    function HandleRequestForTest(const ARequestBody: string): string;
  end;

implementation

uses UDAW.Threading;

const
  SUBSYS = 'AI.MCPServer';
  { MCP revisions UDAW's tools-only server can speak (the tools/list +
    tools/call wire format is identical across them). }
  MCP_SERVER_PROTOCOLS: array[0..2] of string = ('2024-11-05', '2025-03-26', '2025-06-18');
  MCP_SERVER_PROTOCOL_LATEST = '2025-06-18';

{ ================= JSON-RPC dispatch (platform-independent) ================= }

constructor TUDAWMcpServer.Create;
begin
  inherited Create;
  FBindAddress := '127.0.0.1';
  FPort := 8765;
  FAllowDestructive := False;
  FRunning := False;
  FTlsPort := 0;
  FTlsBindAddress := '0.0.0.0';
end;

destructor TUDAWMcpServer.Destroy;
begin
  Stop;
  inherited Destroy;
end;

function TUDAWMcpServer.IsRunning: Boolean;
begin
  Result := FRunning;
end;

function TUDAWMcpServer.IsTlsRunning: Boolean;
begin
  Result := (FTls <> nil) and FTls.IsRunning;
end;

function TUDAWMcpServer.HandleHttpRequest(const AMethod, AAuthHeader, AOrigin, ABody: string;
  out AStatus: Integer): string;
begin
  { Auth first: an unauthenticated caller learns nothing else about the server. }
  if not IsAuthorized(AAuthHeader) then
  begin
    AStatus := 401;
    Exit('{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Unauthorized: missing or invalid bearer token"}}');
  end;
  if not SameText(AMethod, 'POST') then
  begin
    AStatus := 405;   // Streamable HTTP allows 405 for the optional GET push stream
    Exit('');
  end;
  Result := HandleJsonRpc(ABody);
  if Result = '' then AStatus := 202 else AStatus := 200;
end;

function TUDAWMcpServer.IsAuthorized(const AAuthorizationHeader: string): Boolean;
var
  expected, got: string;
  i, diff: Integer;
begin
  if FAuthToken = '' then Exit(True);
  expected := 'Bearer ' + FAuthToken;
  got := Trim(AAuthorizationHeader);
  diff := Length(expected) xor Length(got);
  for i := 1 to Min(Length(expected), Length(got)) do
    diff := diff or (Ord(expected[i]) xor Ord(got[i]));
  Result := diff = 0;
end;

function TUDAWMcpServer.IsOriginAllowed(const AOrigin: string): Boolean;
var
  host: string;
  p: Integer;
begin
  { Origin looks like scheme://host[:port]; only loopback origins are
    accepted, unless the server is deliberately bound off-loopback (then
    the bearer token is the gate and Origin checking is left to it). }
  if (FBindAddress <> '127.0.0.1') and (FBindAddress <> 'localhost') then Exit(True);
  host := LowerCase(AOrigin);
  p := Pos('://', host);
  if p > 0 then host := Copy(host, p + 3, MaxInt);
  p := Pos(':', host);
  if p > 0 then host := Copy(host, 1, p - 1);
  p := Pos('/', host);
  if p > 0 then host := Copy(host, 1, p - 1);
  Result := (host = 'localhost') or (host = '127.0.0.1');
end;

function TUDAWMcpServer.BuildToolsListJSON: string;
var
  o, arr, t, schema, props, p, req, schemaItems: TJSONValue;
  k: TAIToolKind;
  entries, parts: TArray<string>;
  e: string;
begin
  o := JSONObject;
  try
    arr := JSONArray;
    for k := Low(TAIToolKind) to High(TAIToolKind) do
    begin
      t := JSONObject;
      t.AddPair('name', JSONString(AIToolKindId(k)));
      if IsDestructiveTool(k) then
        t.AddPair('description', JSONString('(destructive - requires confirm:true and server AllowDestructive) ' + AIToolDescription(k)))
      else if IsReadOnlyTool(k) then
        t.AddPair('description', JSONString('(read-only) ' + AIToolDescription(k)))
      else
        t.AddPair('description', JSONString(AIToolDescription(k)));
      schema := JSONObject;
      schema.AddPair('type', JSONString('object'));
      props := JSONObject;
      req := JSONArray;
      if AIToolParamSpec(k) <> '' then
      begin
        entries := AIToolParamSpec(k).Split(['|']);
        for e in entries do
        begin
          parts := e.Split([':'], 4);   // name:type:req|opt:description
          if Length(parts) < 4 then Continue;
          p := JSONObject;
          p.AddPair('type', JSONString(parts[1]));
          if parts[1] = 'array' then
          begin
            { JSON Schema wants the element type; every array parameter here is a list of numbers }
            schemaItems := JSONObject;
            schemaItems.AddPair('type', JSONString('number'));
            p.AddPair('items', schemaItems);
          end;
          p.AddPair('description', JSONString(parts[3]));
          props.AddPair(parts[0], p);
          if parts[2] = 'req' then
            req.AddItem(JSONString(parts[0]));
        end;
      end;
      if IsDestructiveTool(k) then
      begin
        p := JSONObject;
        p.AddPair('type', JSONString('boolean'));
        p.AddPair('description', JSONString('Must be true to run this destructive tool'));
        props.AddPair('confirm', p);
      end;
      schema.AddPair('properties', props);
      schema.AddPair('required', req);
      t.AddPair('inputSchema', schema);
      arr.AddItem(t);
    end;
    o.AddPair('tools', arr);
    Result := o.ToJSONString;
  finally
    o.Free;
  end;
end;

function TUDAWMcpServer.BuildToolBlockJSON(const AToolId, AArgsJson: string): string;
var
  v: TJSONValue;
begin
  if Trim(AArgsJson) <> '' then
    v := UDAW.AI.JSON.Parse(AArgsJson)
  else
    v := JSONObject;
  try
    v.AddPair('command', JSONString(AToolId));
    Result := v.ToJSONString;
  finally
    v.Free;
  end;
end;

function TUDAWMcpServer.DispatchToolCall(const AToolId, AArgsJson: string; out AResultText: string): Boolean;
var
  kind: TAIToolKind;
  doc: TProjectDocument;
  cmds: TCommandManager;
  argsVal, confirmVal: TJSONValue;
  confirmed: Boolean;
  toolText, blockText, errMsg: string;
  calls: TArray<TAIToolCall>;
  dispatcher: TAIToolDispatcher;
begin
  Result := False;
  AResultText := '';

  if not AIToolKindFromId(AToolId, kind) then
  begin
    AResultText := Format('unknown tool "%s"', [AToolId]);
    Exit;
  end;

  if IsDestructiveTool(kind) then
  begin
    if not FAllowDestructive then
    begin
      AResultText := Format('tool "%s" is destructive and this MCP server was started with ' +
        'AllowDestructive disabled', [AToolId]);
      Exit;
    end;
    confirmed := False;
    if Trim(AArgsJson) <> '' then
    begin
      argsVal := UDAW.AI.JSON.Parse(AArgsJson);
      try
        confirmVal := argsVal.ByName('confirm');
        confirmed := (confirmVal <> nil) and (confirmVal.Kind = jkBool) and confirmVal.AsBool;
      finally
        argsVal.Free;
      end;
    end;
    if not confirmed then
    begin
      AResultText := Format('tool "%s" is destructive - resend with arguments.confirm = true to proceed',
        [AToolId]);
      Exit;
    end;
  end;

  if not Assigned(FOnGetDoc) or not Assigned(FOnGetCommands) then
  begin
    AResultText := 'this MCP server has no live project attached';
    Exit;
  end;
  doc := FOnGetDoc();
  cmds := FOnGetCommands();
  if (doc = nil) or (cmds = nil) then
  begin
    AResultText := 'no project is currently open';
    Exit;
  end;

  toolText := BuildToolBlockJSON(AToolId, AArgsJson);
  blockText := '```tool' + sLineBreak + toolText + sLineBreak + '```';
  calls := UDAW.AI.ToolCommands.ParseAIToolCalls(blockText);
  if Length(calls) <> 1 then
  begin
    AResultText := Format('could not parse arguments for tool "%s"', [AToolId]);
    Exit;
  end;
  if not ValidateToolCall(calls[0], errMsg) then
  begin
    AResultText := Format('invalid arguments for tool "%s": %s', [AToolId, errMsg]);
    Exit;
  end;

  dispatcher := TAIToolDispatcher.Create(doc, cmds);
  try
    dispatcher.OnTransport := FOnTransport;
    dispatcher.OnUICommand := FOnUICommand;
    if Assigned(FOnGetBrowserRoots) then
      dispatcher.OnGetBrowserRoots := FOnGetBrowserRoots;
    Result := dispatcher.Execute(calls[0], AResultText);
  finally
    dispatcher.Free;
  end;
end;

function TUDAWMcpServer.HandleJsonRpc(const ARequestBody: string): string;
var
  req, resp, params, resultObj, nameVal, argsVal: TJSONValue;
  id: TJSONValue;
  method, toolName, argsJson, resultText, protoVer: string;
  ok: Boolean;
  i: Integer;
begin
  resp := JSONObject;
  try
    resp.AddPair('jsonrpc', JSONString('2.0'));
    try
      req := UDAW.AI.JSON.Parse(ARequestBody);
    except
      resp.AddPair('id', JSONNull);
      resultObj := JSONObject;
      resultObj.AddPair('code', JSONNumber(-32700));
      resultObj.AddPair('message', JSONString('Parse error'));
      resp.AddPair('error', resultObj);
      Exit(resp.ToJSONString);
    end;
    try
      id := req.ByName('id');
      method := '';
      if req.ByName('method') <> nil then
        method := req.ByName('method').AsString;

      { A JSON-RPC notification (no id, e.g. notifications/initialized) gets
        no response body at all - the HTTP layer answers it with 202. }
      if (id = nil) or (id.Kind = jkNull) then
      begin
        if method <> '' then Exit('');
      end;

      { Echo the id in the type the client used (number or string). }
      if id = nil then
        resp.AddPair('id', JSONNull)
      else if id.Kind = jkString then
        resp.AddPair('id', JSONString(id.AsString))
      else if id.Kind = jkNumber then
        resp.AddPair('id', JSONNumber(id.AsNumber))
      else
        resp.AddPair('id', JSONNull);

      if method = 'ping' then
        resp.AddPair('result', JSONObject)
      else if method = 'initialize' then
      begin
        resultObj := JSONObject;
        { Version negotiation: echo the client's protocolVersion when UDAW
          supports it, else answer with the newest one UDAW implements. }
        params := req.ByName('params');
        protoVer := MCP_SERVER_PROTOCOL_LATEST;
        if (params <> nil) and (params.ByName('protocolVersion') <> nil) and
           (params.ByName('protocolVersion').Kind = jkString) then
          for i := Low(MCP_SERVER_PROTOCOLS) to High(MCP_SERVER_PROTOCOLS) do
            if MCP_SERVER_PROTOCOLS[i] = params.ByName('protocolVersion').AsString then
              protoVer := MCP_SERVER_PROTOCOLS[i];
        resultObj.AddPair('protocolVersion', JSONString(protoVer));
        params := JSONObject;
        params.AddPair('tools', JSONObject);
        resultObj.AddPair('capabilities', params);
        argsVal := JSONObject;
        argsVal.AddPair('name', JSONString('UDAW'));
        argsVal.AddPair('version', JSONString('1.0'));
        resultObj.AddPair('serverInfo', argsVal);
        resp.AddPair('result', resultObj);
      end
      else if method = 'tools/list' then
      begin
        resultObj := UDAW.AI.JSON.Parse(BuildToolsListJSON);
        resp.AddPair('result', resultObj);
      end
      else if method = 'tools/call' then
      begin
        params := req.ByName('params');
        toolName := '';
        argsJson := '';
        if params <> nil then
        begin
          nameVal := params.ByName('name');
          if nameVal <> nil then toolName := nameVal.AsString;
          argsVal := params.ByName('arguments');
          if argsVal <> nil then argsJson := argsVal.ToJSONString;
        end;
        ok := DispatchToolCall(toolName, argsJson, resultText);
        resultObj := JSONObject;
        params := JSONArray;
        argsVal := JSONObject;
        argsVal.AddPair('type', JSONString('text'));
        argsVal.AddPair('text', JSONString(resultText));
        params.AddItem(argsVal);
        resultObj.AddPair('content', params);
        resultObj.AddPair('isError', JSONBool(not ok));
        resp.AddPair('result', resultObj);
      end
      else
      begin
        resultObj := JSONObject;
        resultObj.AddPair('code', JSONNumber(-32601));
        resultObj.AddPair('message', JSONString('Method not found: ' + method));
        resp.AddPair('error', resultObj);
      end;
    finally
      req.Free;
    end;
    Result := resp.ToJSONString;
  finally
    resp.Free;
  end;
end;

function TUDAWMcpServer.HandleRequestForTest(const ARequestBody: string): string;
begin
  Result := HandleJsonRpc(ARequestBody);
end;

{$IF DEFINED(MSWINDOWS) AND NOT DEFINED(FPC)}
{ ================= Windows (Delphi): raw Winsock2 loopback HTTP =================
  FPC's Windows RTL exposes the same sockets under a differently-named unit
  ("winsock2", not "Winapi.Winsock2") - rather than guess at FPC's exact API
  surface untested, this transport is Delphi-only for now, matching this
  project's "Windows/Delphi 12 is the only verified target" stance elsewhere
  (see the platform-focus memory / Phase 2's native-backend caveat). The
  JSON-RPC dispatch above (HandleJsonRpc/HandleRequestForTest) is already
  fully platform-independent and unit-tested without any socket at all. }

type
  TMcpAcceptThread = class(TUDAWThread)
  private
    FOwner: TUDAWMcpServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TUDAWMcpServer);
  end;

  TMcpWorkerThread = class(TUDAWThread)
  private
    FOwner: TUDAWMcpServer;
    FClient: TSocket;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TUDAWMcpServer; AClient: TSocket);
  end;

constructor TMcpAcceptThread.Create(AOwner: TUDAWMcpServer);
begin
  inherited Create(False);
  FOwner := AOwner;
  FreeOnTerminate := False;
end;

procedure TMcpAcceptThread.Execute;
var
  client: TSocket;
begin
  while not Terminated do
  begin
    client := accept(FOwner.FListenSocket, nil, nil);
    if client = INVALID_SOCKET then
    begin
      if Terminated then Break;
      Continue;
    end;
    TMcpWorkerThread.Create(FOwner, client);  // FreeOnTerminate - fire and forget
  end;
end;

constructor TMcpWorkerThread.Create(AOwner: TUDAWMcpServer; AClient: TSocket);
begin
  inherited Create(False);
  FOwner := AOwner;
  FClient := AClient;
  FreeOnTerminate := True;
end;

procedure TMcpWorkerThread.Execute;
const
  MAX_REQUEST_BYTES = 1 * 1024 * 1024;
var
  buf: array[0..4095] of AnsiChar;
  raw: TBytes;
  n, headerEnd, contentLen, bodyStart: Integer;
  headerText, line, body, respBody, httpResp, authHeader, originHeader: string;
  lines: TArray<string>;
  i: Integer;
  isPost: Boolean;
begin
  try
    SetLength(raw, 0);
    headerEnd := 0;
    headerText := '';
    { read until we see the blank-line header terminator, or hit the safety cap }
    while (headerEnd <= 0) and (Length(raw) < MAX_REQUEST_BYTES) do
    begin
      n := recv(FClient, buf, SizeOf(buf), 0);
      if n <= 0 then Break;
      SetLength(raw, Length(raw) + n);
      Move(buf, raw[Length(raw) - n], n);
      headerText := TEncoding.ASCII.GetString(raw);
      headerEnd := Pos(#13#10#13#10, headerText);
    end;
    if headerEnd <= 0 then Exit;

    contentLen := 0;
    authHeader := '';
    originHeader := '';
    lines := Copy(headerText, 1, headerEnd - 1).Split([#13#10]);
    isPost := (Length(lines) > 0) and (Pos('POST ', UpperCase(lines[0])) = 1);
    for i := 0 to High(lines) do
    begin
      line := lines[i];
      if Pos('content-length:', LowerCase(line)) = 1 then
        contentLen := StrToIntDef(Trim(Copy(line, Pos(':', line) + 1, MaxInt)), 0)
      else if Pos('authorization:', LowerCase(line)) = 1 then
        authHeader := Trim(Copy(line, Pos(':', line) + 1, MaxInt))
      else if Pos('origin:', LowerCase(line)) = 1 then
        originHeader := Trim(Copy(line, Pos(':', line) + 1, MaxInt));
    end;

    { Streamable-HTTP clients may probe with GET for a server-push stream;
      UDAW only answers POSTed JSON-RPC, which the spec allows via 405. }
    if not isPost then
    begin
      raw := TEncoding.ASCII.GetBytes('HTTP/1.1 405 Method Not Allowed'#13#10 +
        'Allow: POST'#13#10'Content-Length: 0'#13#10'Connection: close'#13#10#13#10);
      send(FClient, raw[0], Length(raw), 0);
      Exit;
    end;

    { DNS-rebinding guard (MCP transport spec): a browser page on another
      origin must not be able to drive a loopback-bound server. Requests
      with no Origin header (every non-browser MCP client) are unaffected. }
    if (originHeader <> '') and not FOwner.IsOriginAllowed(originHeader) then
    begin
      raw := TEncoding.ASCII.GetBytes('HTTP/1.1 403 Forbidden'#13#10 +
        'Content-Length: 0'#13#10'Connection: close'#13#10#13#10);
      send(FClient, raw[0], Length(raw), 0);
      Exit;
    end;

    bodyStart := headerEnd + 3;   // position of the byte right after the blank line, 0-based via -1 below
    while Length(raw) - bodyStart < contentLen do
    begin
      n := recv(FClient, buf, SizeOf(buf), 0);
      if n <= 0 then Break;
      SetLength(raw, Length(raw) + n);
      Move(buf, raw[Length(raw) - n], n);
    end;

    body := '';
    if Length(raw) > bodyStart then
      body := TEncoding.UTF8.GetString(raw, bodyStart, Min(contentLen, Length(raw) - bodyStart));

    if not FOwner.IsAuthorized(authHeader) then
    begin
      respBody := '{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Unauthorized: missing or invalid bearer token"}}';
      raw := TEncoding.UTF8.GetBytes('HTTP/1.1 401 Unauthorized'#13#10 +
        'WWW-Authenticate: Bearer'#13#10 +
        'Content-Type: application/json'#13#10 +
        'Content-Length: ' + IntToStr(Length(TEncoding.UTF8.GetBytes(respBody))) + #13#10 +
        'Connection: close'#13#10#13#10 + respBody);
      send(FClient, raw[0], Length(raw), 0);
      Exit;
    end;

    try
      respBody := FOwner.HandleJsonRpc(body);
    except
      on E: Exception do
      begin
        var errVal := UDAW.AI.JSON.JSONString(E.Message);
        try
          respBody := Format('{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":%s}}',
            [errVal.ToJSONString]);
        finally
          errVal.Free;
        end;
      end;
    end;

    if respBody = '' then   // a JSON-RPC notification: accepted, no body
    begin
      raw := TEncoding.ASCII.GetBytes('HTTP/1.1 202 Accepted'#13#10 +
        'Content-Length: 0'#13#10'Connection: close'#13#10#13#10);
      send(FClient, raw[0], Length(raw), 0);
      Exit;
    end;

    httpResp := 'HTTP/1.1 200 OK'#13#10 +
      'Content-Type: application/json'#13#10 +
      'Content-Length: ' + IntToStr(Length(TEncoding.UTF8.GetBytes(respBody))) + #13#10 +
      'Connection: close'#13#10#13#10 +
      respBody;
    raw := TEncoding.UTF8.GetBytes(httpResp);
    send(FClient, raw[0], Length(raw), 0);
  finally
    shutdown(FClient, SD_BOTH);
    closesocket(FClient);
  end;
end;

procedure TUDAWMcpServer.Start;
var
  wsaData: TWSAData;
  addr: TSockAddrIn;
  opt: Integer;
begin
  if FRunning then Exit;

  if (FTlsPort > 0) and (Trim(FAuthToken) = '') then
    RaiseUDAW(errInvalidArgument, SUBSYS,
      'refusing to open the HTTPS listener without an auth token - a remotely reachable MCP server must be authenticated');

  if (FAuthToken = '') and (FBindAddress <> '127.0.0.1') and (FBindAddress <> 'localhost') then
    RaiseUDAW(errInvalidArgument, SUBSYS,
      'refusing to listen on a non-loopback address without an auth token');

  if WSAStartup($0202, wsaData) <> 0 then
    RaiseUDAW(errNetwork, SUBSYS, 'WSAStartup failed');
  FWsaStarted := True;

  FListenSocket := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if FListenSocket = INVALID_SOCKET then
  begin
    WSACleanup;
    FWsaStarted := False;
    RaiseUDAWFmt(errNetwork, SUBSYS, 'socket() failed (WSA error %d)', [WSAGetLastError]);
  end;

  opt := 1;
  setsockopt(FListenSocket, SOL_SOCKET, SO_REUSEADDR, @opt, SizeOf(opt));

  FillChar(addr, SizeOf(addr), 0);
  addr.sin_family := AF_INET;
  addr.sin_port := htons(Word(FPort));
  addr.sin_addr.S_addr := inet_addr(PAnsiChar(AnsiString(FBindAddress)));
  if addr.sin_addr.S_addr = INADDR_NONE then
    addr.sin_addr.S_addr := htonl(INADDR_LOOPBACK);

  if bind(FListenSocket, TSockAddr(addr), SizeOf(addr)) <> 0 then
  begin
    closesocket(FListenSocket);
    WSACleanup;
    FWsaStarted := False;
    RaiseUDAWFmt(errNetwork, SUBSYS, 'bind() to %s:%d failed (WSA error %d)',
      [FBindAddress, FPort, WSAGetLastError]);
  end;

  if listen(FListenSocket, 8) <> 0 then
  begin
    closesocket(FListenSocket);
    WSACleanup;
    FWsaStarted := False;
    RaiseUDAWFmt(errNetwork, SUBSYS, 'listen() failed (WSA error %d)', [WSAGetLastError]);
  end;

  FRunning := True;
  FAcceptThread := TMcpAcceptThread.Create(Self);
  AISecureLog.Info(SUBSYS, Format('MCP server listening on %s:%d (destructive tools %s)',
    [FBindAddress, FPort, IfThen(FAllowDestructive, 'ALLOWED', 'blocked')]));

  if FTlsPort > 0 then
  begin
    FTls := TMcpTlsListener.Create;
    FTls.Port := FTlsPort;
    FTls.BindAddress := FTlsBindAddress;
    FTls.CertFile := FTlsCertFile;
    FTls.KeyFile := FTlsKeyFile;
    FTls.KeyPassword := FTlsKeyPassword;
    FTls.OnRequest := HandleHttpRequest;
    try
      FTls.Start;
    except
      FreeAndNil(FTls);
      Stop;          // never leave half a server running
      raise;
    end;
  end;
end;

procedure TUDAWMcpServer.Stop;
begin
  FreeAndNil(FTls);
  if not FRunning then Exit;
  FRunning := False;
  if FAcceptThread <> nil then
  begin
    FAcceptThread.Terminate;
    closesocket(FListenSocket);   // unblocks accept()
    FAcceptThread.WaitFor;
    FreeAndNil(FAcceptThread);
  end;
  if FWsaStarted then
  begin
    WSACleanup;
    FWsaStarted := False;
  end;
  AISecureLog.Info(SUBSYS, 'MCP server stopped');
end;

{$ELSE}

procedure TUDAWMcpServer.Start;
begin
  RaiseUDAW(errNotImplemented, SUBSYS,
    'exposing UDAW as an MCP server is only implemented on Windows/Delphi today');
end;

procedure TUDAWMcpServer.Stop;
begin
  FreeAndNil(FTls);
  FRunning := False;
end;

{$ENDIF}

end.
