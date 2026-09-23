unit UDAW.AI.MCP;
{$I udaw.inc}

{ Phase 20/26 - Model Context Protocol support (plan section 79, docs/
  UDAW-Original-Plan.txt lines 4460-4551). This unit delivers the full
  client-side stack described there: IMCPTransport (stdio and HTTP), a
  capability-negotiating IMCPClient (initialize/list_tools/list_resources/
  list_prompts/call_tool/read_resource/get_prompt/cancel), and a persisted
  TMCPServerRegistry. TMCPToolBridge (wiring discovered tools into the AI
  Orchestrator's tool vocabulary) lives in UDAW.AI.MCPBridge, one layer up,
  since it depends on the tool-call parsing conventions already established
  by UDAW.AI.ToolCommands. TUDAWMcpServer (exposing UDAW itself as an MCP
  server) lives in UDAW.AI.MCPServer.

  The stdio transport uses the real MCP stdio framing: newline-delimited
  JSON-RPC 2.0 messages, one message per line - NOT Content-Length/HTTP-style
  framing. A background reader thread drains the child process's stdout line
  by line into a thread-safe queue; SendRequest writes the request line then
  polls that queue (with a timeout) for a response whose "id" matches. This
  is the standard, deliberately simple pattern for a foundation layer - not
  a general async pub/sub notification system. Because the client is
  synchronous, "cancel" (plan: IMCPClient exposes cancel) is necessarily
  best-effort: it fires the "notifications/cancelled" notification for a
  request id, but only a caller running CallTool on its own thread can
  usefully race that against an in-flight SendRequest. }

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections,
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  {$IF DEFINED(UDAW_MACOS) OR DEFINED(UDAW_POSIX)}
  Process,
  {$IFEND}
  UDAW.Errors, UDAW.Paths, UDAW.AI.JSON, UDAW.AI.HTTP;

const
  MCP_PROTOCOL_VERSION = '2024-11-05';

type
  { A per-server-process environment override: "KEY=VALUE". The stdio
    transport inherits the current process environment and applies these on
    top of it (added or replaced), matching the plan's per-server "env"
    setting - it never REPLACES the whole environment, since MCP servers
    written in Node/Python/etc. typically need PATH and friends intact. }
  TMCPEnvVar = record
    Name: string;
    Value: string;
  end;

  IMCPTransport = interface
    ['{4F6C8A12-9D3B-4E7A-8C1F-2B5D6E9A0731}']
    function IsConnected: Boolean;
    procedure Start;
    procedure Stop;
    { Blocking: sends one JSON-RPC 2.0 request string and returns the
      matching JSON-RPC response string. Framing/correlation is the
      transport's job. }
    function SendRequest(const AJsonRpcRequest: string): string;
    { Fire-and-forget: a JSON-RPC notification (no "id", no response
      expected/awaited). Used for "notifications/initialized" and
      "notifications/cancelled". Errors are swallowed - a notification that
      fails to send never blocks or raises, matching the plan's "an MCP
      server that errors or times out never blocks the UI" rule. }
    procedure SendNotification(const AJsonRpcNotification: string);
  end;

  { Newline-delimited JSON-RPC 2.0 over a child process's stdin/stdout. }
  TMCPStdioTransport = class(TInterfacedObject, IMCPTransport)
  private
    FCommandLine: string;
    FTimeoutMs: Integer;
    FConnected: Boolean;
    FEnvironment: TArray<TMCPEnvVar>;
    FRespLock: TCriticalSection;
    FResponseLines: TStringList;
    FReaderThread: TThread;
    {$IFDEF MSWINDOWS}
    FProcessHandle: THandle;
    FThreadHandle: THandle;
    FStdinWrite: THandle;
    FStdoutRead: THandle;
    {$ELSE}
    FProcess: TProcess;
    {$ENDIF}
    procedure OnLineReceived(const ALine: string);
    function TryExtractId(const ALine: string; out AIdText: string): Boolean;
    procedure WriteLine(const ALine: string);
    {$IFDEF MSWINDOWS}
    function BuildEnvironmentBlock: TBytes;
    {$ENDIF}
  public
    constructor Create;
    destructor Destroy; override;
    property CommandLine: string read FCommandLine write FCommandLine;
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
    property Environment: TArray<TMCPEnvVar> read FEnvironment write FEnvironment;
    function IsConnected: Boolean;
    procedure Start;
    procedure Stop;
    function SendRequest(const AJsonRpcRequest: string): string;
    procedure SendNotification(const AJsonRpcNotification: string);
  end;

  { HTTP+JSON-RPC MCP transport variant, on top of UDAW.AI.HTTP.TAIHttpClient.
    Implements Streamable-HTTP MCP's POST shape: the request advertises
    "Accept: application/json, text/event-stream" and the reply may be bare
    JSON or a single SSE message event. Server-initiated push streams (GET)
    and Mcp-Session-Id tracking are not implemented (TAIHttpResponse exposes
    no headers), so servers that mandate a session id are unsupported. }
  TMCPHttpTransport = class(TInterfacedObject, IMCPTransport)
  private
    FEndpoint: string;
    FHttp: TAIHttpClient;
    FConnected: Boolean;
    FBearerToken: string;
    function BuildHeaders: TArray<TAIHttpHeader>;
  public
    { Returns the JSON-RPC payload of an HTTP reply body, whether it is bare
      JSON or an SSE stream ("data: <json>"). Public for unit testing. }
    class function ExtractJsonPayload(const ABody: string): string; static;
    constructor Create;
    destructor Destroy; override;
    property Endpoint: string read FEndpoint write FEndpoint;
    { Sent as 'Authorization: Bearer <token>' on every request when non-empty. }
    property BearerToken: string read FBearerToken write FBearerToken;
    function IsConnected: Boolean;
    procedure Start;
    procedure Stop;
    function SendRequest(const AJsonRpcRequest: string): string;
    procedure SendNotification(const AJsonRpcNotification: string);
  end;

  { A discovered tool, resource or prompt, as advertised by "tools/list",
    "resources/list" and "prompts/list" respectively. InputSchemaJson /
    ArgumentsJson are the raw JSON Schema / argument-list sub-objects,
    passed through unparsed - TMCPToolBridge (one layer up) is the thing
    that turns these into a system-prompt fragment, not this unit. }
  TMCPToolInfo = record
    Name: string;
    Description: string;
    InputSchemaJson: string;
  end;

  TMCPResourceInfo = record
    Uri: string;
    Name: string;
    Description: string;
    MimeType: string;
  end;

  TMCPPromptInfo = record
    Name: string;
    Description: string;
    ArgumentsJson: string;
  end;

  { capabilities the server advertised in its "initialize" response - only
    the pieces UDAW's client actually branches on. }
  TMCPServerCapabilities = record
    HasTools: Boolean;
    HasResources: Boolean;
    HasPrompts: Boolean;
    ServerName: string;
    ServerVersion: string;
  end;

  IMCPClient = interface
    ['{7A1E4C90-2F6B-4D8A-B3E5-9C0F1A2D3E48}']
    { Performs the MCP handshake: sends "initialize" (protocolVersion,
      capabilities, clientInfo), then fires "notifications/initialized".
      Must succeed before any list_*/call_tool/read_resource/get_prompt
      call. Returns False (does not raise) if the server never answers
      "initialize" within the transport's timeout - callers degrade to
      "that server is unavailable" per the plan's availability rule. }
    function Initialize(ATransport: IMCPTransport): Boolean;
    function IsInitialized: Boolean;
    { Why the last Initialize failed (empty when it succeeded). }
    function LastError: string;
    function Capabilities: TMCPServerCapabilities;
    function ListTools: TArray<string>;
    function ListToolsDetailed: TArray<TMCPToolInfo>;
    function ListResources: TArray<TMCPResourceInfo>;
    function ReadResource(const AUri: string): string;
    function ListPrompts: TArray<TMCPPromptInfo>;
    function GetPrompt(const AName: string; const AArgsJson: string): string;
    function CallTool(const AToolName: string; const AArgsJson: string): string;
    { Best-effort: fires "notifications/cancelled" for a previously issued
      request id. See the unit header comment for why this is best-effort
      with a synchronous transport. }
    procedure CancelRequest(ARequestId: Integer);
    function LastRequestId: Integer;
  end;

  TMCPClient = class(TInterfacedObject, IMCPClient)
  private
    FTransport: IMCPTransport;
    FNextId: Integer;
    FLastId: Integer;
    FInitialized: Boolean;
    FLastError: string;
    FCaps: TMCPServerCapabilities;
    function NextRequestId: Integer;
    function BuildRequest(const AMethod: string; AParams: TJSONValue; AId: Integer): string;
    function BuildNotification(const AMethod: string; AParams: TJSONValue): string;
    function SendAndParse(const AMethod: string; AParams: TJSONValue): TJSONValue;
    procedure RequireInitialized;
  public
    constructor Create;
    function Initialize(ATransport: IMCPTransport): Boolean;
    function IsInitialized: Boolean;
    function LastError: string;
    function Capabilities: TMCPServerCapabilities;
    function ListTools: TArray<string>;
    function ListToolsDetailed: TArray<TMCPToolInfo>;
    function ListResources: TArray<TMCPResourceInfo>;
    function ReadResource(const AUri: string): string;
    function ListPrompts: TArray<TMCPPromptInfo>;
    function GetPrompt(const AName: string; const AArgsJson: string): string;
    function CallTool(const AToolName: string; const AArgsJson: string): string;
    procedure CancelRequest(ARequestId: Integer);
    function LastRequestId: Integer;
  end;

  TMCPServerConfig = record
    Name: string;
    CommandLine: string;
    HttpEndpoint: string;
    UseStdio: Boolean;
    Enabled: Boolean;
    TimeoutMs: Integer;
    { Empty = every tool the server advertises may be called. Non-empty =
      only these tool names may be called (plan: "per-server ... allowed
      tool allow-list"). Enforced by TMCPToolBridge, not by this record. }
    AllowedTools: TArray<string>;
    Environment: TArray<TMCPEnvVar>;
    class function Default(const AName: string): TMCPServerConfig; static;
  end;

  { Registry of user-configured MCP servers, persisted as a small
    line-oriented text file (mirrors the style of every other UDAW
    serializer - no JSON/XML library, hand-written parse/format) at
    UDAW.Paths.ConfigFile('mcp_servers.cfg'). Load is called once at
    startup; Save after every Add/Remove/Update so a crash never loses a
    configured server list. }
  TMCPServerRegistry = class
  private
    FLock: TCriticalSection;
    FItems: TArray<TMCPServerConfig>;
    function IndexOf(const AName: string): Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(const AConfig: TMCPServerConfig);
    procedure Update(const AConfig: TMCPServerConfig);
    procedure Remove(const AName: string);
    function Count: Integer;
    function GetConfig(AIndex: Integer): TMCPServerConfig;
    function FindByName(const AName: string; out AConfig: TMCPServerConfig): Boolean;
    procedure SaveToFile(const APath: string);
    procedure LoadFromFile(const APath: string);
    procedure Save;
    procedure Load;
  end;

function MCPServerRegistry: TMCPServerRegistry;
function MCPDefaultRegistryPath: string;

implementation

const
  SUBSYS = 'AI.MCP';

{ ================= TMCPStdioTransport ================= }

type
  { Reads the child process's stdout continuously and pushes complete lines
    to the owning transport via OnLineReceived. Platform-specific read loop,
    common outer shape. }
  TMCPStdioReaderThread = class(TThread)
  private
    FOwner: TMCPStdioTransport;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TMCPStdioTransport);
  end;

constructor TMCPStdioReaderThread.Create(AOwner: TMCPStdioTransport);
begin
  inherited Create(False);
  FOwner := AOwner;
  FreeOnTerminate := False;
end;

procedure TMCPStdioReaderThread.Execute;
var
  buf: array[0..4095] of Byte;
  lineBuf: TStringBuilder;
  {$IFDEF MSWINDOWS}
  bytesRead: DWORD;
  ok: BOOL;
  {$ELSE}
  n: LongInt;
  {$ENDIF}
  i: Integer;
  c: AnsiChar;
begin
  lineBuf := TStringBuilder.Create;
  try
    while not Terminated do
    begin
      {$IFDEF MSWINDOWS}
      ok := ReadFile(FOwner.FStdoutRead, buf, SizeOf(buf), bytesRead, nil);
      if (not ok) or (bytesRead = 0) then
        Break;
      for i := 0 to bytesRead - 1 do
      begin
        c := AnsiChar(buf[i]);
        if c = #10 then
        begin
          FOwner.OnLineReceived(lineBuf.ToString);
          lineBuf.Clear;
        end
        else if c <> #13 then
          lineBuf.Append(Char(c));
      end;
      {$ELSE}
      if (FOwner.FProcess = nil) or (not FOwner.FProcess.Running) then
        Break;
      n := FOwner.FProcess.Output.NumBytesAvailable;
      if n = 0 then
      begin
        Sleep(5);
        Continue;
      end;
      if n > SizeOf(buf) then n := SizeOf(buf);
      n := FOwner.FProcess.Output.Read(buf, n);
      for i := 0 to n - 1 do
      begin
        c := AnsiChar(buf[i]);
        if c = #10 then
        begin
          FOwner.OnLineReceived(lineBuf.ToString);
          lineBuf.Clear;
        end
        else if c <> #13 then
          lineBuf.Append(Char(c));
      end;
      {$ENDIF}
    end;
  finally
    lineBuf.Free;
  end;
end;

constructor TMCPStdioTransport.Create;
begin
  inherited Create;
  FTimeoutMs := 10000;
  FConnected := False;
  FRespLock := TCriticalSection.Create;
  FResponseLines := TStringList.Create;
  {$IFDEF MSWINDOWS}
  FProcessHandle := 0;
  FThreadHandle := 0;
  FStdinWrite := 0;
  FStdoutRead := 0;
  {$ELSE}
  FProcess := nil;
  {$ENDIF}
end;

destructor TMCPStdioTransport.Destroy;
begin
  Stop;
  FResponseLines.Free;
  FRespLock.Free;
  inherited Destroy;
end;

procedure TMCPStdioTransport.OnLineReceived(const ALine: string);
begin
  if Trim(ALine) = '' then
    Exit;
  FRespLock.Enter;
  try
    FResponseLines.Add(ALine);
  finally
    FRespLock.Leave;
  end;
end;

function TMCPStdioTransport.TryExtractId(const ALine: string; out AIdText: string): Boolean;
var
  v, idVal: TJSONValue;
begin
  AIdText := '';
  try
    v := UDAW.AI.JSON.Parse(ALine);
  except
    Exit(False);
  end;
  try
    if (v = nil) or (v.Kind <> jkObject) then
      Exit(False);
    idVal := v.ByName('id');
    if idVal = nil then
      Exit(False);
    case idVal.Kind of
      jkNumber: AIdText := IntToStr(Trunc(idVal.AsNumber));
      jkString: AIdText := idVal.AsString;
    else
      Exit(False);
    end;
    Result := True;
  finally
    v.Free;
  end;
end;

procedure TMCPStdioTransport.WriteLine(const ALine: string);
var
  bytes: TBytes;
  {$IFDEF MSWINDOWS}
  written: DWORD;
  {$ELSE}
  s: string;
  {$ENDIF}
begin
  bytes := TEncoding.UTF8.GetBytes(ALine + #10);
  {$IFDEF MSWINDOWS}
  if not WriteFile(FStdinWrite, bytes[0], Length(bytes), written, nil) then
    RaiseUDAWFmt(errNetwork, SUBSYS, 'failed to write to MCP server stdin (error %d)', [GetLastError]);
  {$ELSE}
  s := ALine + #10;
  if (FProcess = nil) or (not FProcess.Running) then
    RaiseUDAW(errInvalidState, SUBSYS, 'MCP server process is not running');
  FProcess.Input.Write(s[1], Length(s));
  {$ENDIF}
end;

{$IFDEF MSWINDOWS}
function TMCPStdioTransport.BuildEnvironmentBlock: TBytes;
var
  inherited_: PChar;
  p: PChar;
  s: string;
  sb: TStringBuilder;
  i: Integer;
  overridden: TArray<Boolean>;
  name, rest: string;
  eqPos: Integer;
begin
  { CreateProcess wants a double-null-terminated block of "NAME=VALUE\0"
    strings. We inherit the current process's block wholesale (so PATH,
    TEMP, etc. are intact for whatever runtime the MCP server needs) and
    then apply FEnvironment on top - replacing a variable that already
    exists (case-insensitively, as Windows env vars are) or appending one
    that doesn't. }
  SetLength(overridden, Length(FEnvironment));
  sb := TStringBuilder.Create;
  try
    inherited_ := GetEnvironmentStrings;
    if inherited_ <> nil then
    begin
      try
        p := inherited_;
        while p^ <> #0 do
        begin
          s := string(p);
          eqPos := Pos('=', s);
          if eqPos > 1 then
          begin
            name := Copy(s, 1, eqPos - 1);
            rest := s;
            for i := 0 to High(FEnvironment) do
              if SameText(FEnvironment[i].Name, name) then
              begin
                rest := FEnvironment[i].Name + '=' + FEnvironment[i].Value;
                overridden[i] := True;
                Break;
              end;
            sb.Append(rest).Append(#0);
          end
          else
            sb.Append(s).Append(#0);
          Inc(p, Length(s) + 1);
        end;
      finally
        FreeEnvironmentStrings(inherited_);
      end;
    end;
    for i := 0 to High(FEnvironment) do
      if not overridden[i] then
        sb.Append(FEnvironment[i].Name).Append('=').Append(FEnvironment[i].Value).Append(#0);
    sb.Append(#0);
    Result := TEncoding.Unicode.GetBytes(sb.ToString);
  finally
    sb.Free;
  end;
end;

procedure TMCPStdioTransport.Start;
var
  saAttr: TSecurityAttributes;
  stdoutWrite, stdinRead: THandle;
  si: TStartupInfo;
  pi: TProcessInformation;
  cmdLine: string;
  envBlock: TBytes;
  envPtr: Pointer;
begin
  if FConnected then
    Exit;
  if Trim(FCommandLine) = '' then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'MCP stdio transport: CommandLine not set');

  FillChar(saAttr, SizeOf(saAttr), 0);
  saAttr.nLength := SizeOf(saAttr);
  saAttr.bInheritHandle := True;
  saAttr.lpSecurityDescriptor := nil;

  if not CreatePipe(FStdoutRead, stdoutWrite, @saAttr, 0) then
    RaiseUDAWFmt(errPlatform, SUBSYS, 'CreatePipe (stdout) failed (error %d)', [GetLastError]);
  if not SetHandleInformation(FStdoutRead, HANDLE_FLAG_INHERIT, 0) then
    RaiseUDAWFmt(errPlatform, SUBSYS, 'SetHandleInformation (stdout) failed (error %d)', [GetLastError]);

  if not CreatePipe(stdinRead, FStdinWrite, @saAttr, 0) then
    RaiseUDAWFmt(errPlatform, SUBSYS, 'CreatePipe (stdin) failed (error %d)', [GetLastError]);
  if not SetHandleInformation(FStdinWrite, HANDLE_FLAG_INHERIT, 0) then
    RaiseUDAWFmt(errPlatform, SUBSYS, 'SetHandleInformation (stdin) failed (error %d)', [GetLastError]);

  FillChar(si, SizeOf(si), 0);
  si.cb := SizeOf(si);
  si.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
  si.wShowWindow := SW_HIDE;
  si.hStdInput := stdinRead;
  si.hStdOutput := stdoutWrite;
  si.hStdError := stdoutWrite;

  FillChar(pi, SizeOf(pi), 0);
  cmdLine := FCommandLine;
  UniqueString(cmdLine);

  envPtr := nil;
  if Length(FEnvironment) > 0 then
  begin
    envBlock := BuildEnvironmentBlock;
    envPtr := @envBlock[0];
  end;

  if not CreateProcess(nil, PChar(cmdLine), nil, nil, True,
       CREATE_NO_WINDOW or CREATE_UNICODE_ENVIRONMENT, envPtr, nil, si, pi) then
  begin
    CloseHandle(FStdoutRead); CloseHandle(stdoutWrite);
    CloseHandle(stdinRead); CloseHandle(FStdinWrite);
    RaiseUDAWFmt(errPlatform, SUBSYS, 'failed to launch MCP server "%s" (error %d)',
      [FCommandLine, GetLastError]);
  end;

  CloseHandle(stdoutWrite);   // child's write end - our copy not needed
  CloseHandle(stdinRead);     // child's read end - our copy not needed

  FProcessHandle := pi.hProcess;
  FThreadHandle := pi.hThread;

  FConnected := True;
  FReaderThread := TMCPStdioReaderThread.Create(Self);
end;

procedure TMCPStdioTransport.Stop;
begin
  if not FConnected then
    Exit;
  FConnected := False;
  if FReaderThread <> nil then
  begin
    FReaderThread.Terminate;
  end;
  if FStdinWrite <> 0 then
  begin
    CloseHandle(FStdinWrite);
    FStdinWrite := 0;
  end;
  if FProcessHandle <> 0 then
  begin
    TerminateProcess(FProcessHandle, 0);
    WaitForSingleObject(FProcessHandle, 2000);
    CloseHandle(FProcessHandle);
    FProcessHandle := 0;
  end;
  if FThreadHandle <> 0 then
  begin
    CloseHandle(FThreadHandle);
    FThreadHandle := 0;
  end;
  if FStdoutRead <> 0 then
  begin
    CloseHandle(FStdoutRead);
    FStdoutRead := 0;
  end;
  if FReaderThread <> nil then
  begin
    FReaderThread.WaitFor;
    FreeAndNil(FReaderThread);
  end;
end;
{$ELSE}
procedure TMCPStdioTransport.Start;
var
  parts: TStringList;
  i: Integer;
begin
  if FConnected then
    Exit;
  if Trim(FCommandLine) = '' then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'MCP stdio transport: CommandLine not set');

  FProcess := TProcess.Create(nil);
  parts := TStringList.Create;
  try
    parts.Delimiter := ' ';
    parts.StrictDelimiter := True;
    parts.DelimitedText := FCommandLine;
    if parts.Count = 0 then
      RaiseUDAW(errInvalidArgument, SUBSYS, 'MCP stdio transport: empty CommandLine');
    FProcess.Executable := parts[0];
    for i := 1 to parts.Count - 1 do
      FProcess.Parameters.Add(parts[i]);
  finally
    parts.Free;
  end;
  FProcess.Options := [poUsePipes, poNoConsole];
  try
    FProcess.Execute;
  except
    on E: Exception do
      RaiseUDAWFmt(errPlatform, SUBSYS, 'failed to launch MCP server "%s": %s',
        [FCommandLine, E.Message]);
  end;

  FConnected := True;
  FReaderThread := TMCPStdioReaderThread.Create(Self);
end;

procedure TMCPStdioTransport.Stop;
begin
  if not FConnected then
    Exit;
  FConnected := False;
  if FReaderThread <> nil then
    FReaderThread.Terminate;
  if FProcess <> nil then
  begin
    FProcess.CloseInput;
    try
      if FProcess.Running then
        FProcess.Terminate(0);
    except
    end;
  end;
  if FReaderThread <> nil then
  begin
    FReaderThread.WaitFor;
    FreeAndNil(FReaderThread);
  end;
  FreeAndNil(FProcess);
end;
{$ENDIF}

function TMCPStdioTransport.IsConnected: Boolean;
begin
  Result := FConnected;
end;

function TMCPStdioTransport.SendRequest(const AJsonRpcRequest: string): string;
var
  wantId: string;
  gotId: string;
  deadline: TDateTime;
  i: Integer;
  found: Boolean;
  line: string;
begin
  if not FConnected then
    RaiseUDAW(errInvalidState, SUBSYS, 'MCP stdio transport is not started');
  if not TryExtractId(AJsonRpcRequest, wantId) then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'JSON-RPC request has no "id" field to correlate a response');

  WriteLine(AJsonRpcRequest);

  deadline := Now + (FTimeoutMs / MSecsPerDay);
  Result := '';
  found := False;
  while not found do
  begin
    FRespLock.Enter;
    try
      for i := 0 to FResponseLines.Count - 1 do
      begin
        line := FResponseLines[i];
        if TryExtractId(line, gotId) and (gotId = wantId) then
        begin
          Result := line;
          FResponseLines.Delete(i);
          found := True;
          Break;
        end;
      end;
    finally
      FRespLock.Leave;
    end;
    if found then
      Break;
    if Now > deadline then
      RaiseUDAWFmt(errTimeout, SUBSYS, 'MCP request (id=%s) timed out after %d ms', [wantId, FTimeoutMs]);
    Sleep(10);
  end;
end;

procedure TMCPStdioTransport.SendNotification(const AJsonRpcNotification: string);
begin
  if not FConnected then Exit;
  try
    WriteLine(AJsonRpcNotification);
  except
    { best-effort - see unit header comment }
  end;
end;

{ ================= TMCPHttpTransport ================= }

constructor TMCPHttpTransport.Create;
begin
  inherited Create;
  FHttp := TAIHttpClient.Create;
  FConnected := False;
end;

destructor TMCPHttpTransport.Destroy;
begin
  FHttp.Free;
  inherited Destroy;
end;

function TMCPHttpTransport.IsConnected: Boolean;
begin
  Result := FConnected;
end;

procedure TMCPHttpTransport.Start;
begin
  if Trim(FEndpoint) = '' then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'MCP HTTP transport: Endpoint not set');
  FConnected := True;
end;

procedure TMCPHttpTransport.Stop;
begin
  FConnected := False;
end;

function TMCPHttpTransport.BuildHeaders: TArray<TAIHttpHeader>;
begin
  { Streamable-HTTP MCP servers require the client to accept BOTH a plain
    JSON reply and an SSE stream; MCP-Protocol-Version names the revision
    negotiated by initialize. Authorization only when a token is configured. }
  SetLength(Result, 3);
  Result[0].Name := 'Content-Type';
  Result[0].Value := 'application/json';
  Result[1].Name := 'Accept';
  Result[1].Value := 'application/json, text/event-stream';
  Result[2].Name := 'MCP-Protocol-Version';
  Result[2].Value := MCP_PROTOCOL_VERSION;
  if FBearerToken <> '' then
  begin
    SetLength(Result, 4);
    Result[3].Name := 'Authorization';
    Result[3].Value := 'Bearer ' + FBearerToken;
  end;
end;

{ A Streamable-HTTP server may answer a POST with an SSE stream
  ("event: message" / "data: <json>") instead of a bare JSON body. Returns
  the JSON-RPC payload either way. }
class function TMCPHttpTransport.ExtractJsonPayload(const ABody: string): string;
var
  t, line, data: string;
  lines: TArray<string>;
begin
  t := Trim(ABody);
  if (t = '') or (t[1] = '{') or (t[1] = '[') then Exit(t);
  Result := t;
  data := '';
  lines := StringReplace(t, #13, '', [rfReplaceAll]).Split([#10]);
  for line in lines do
  begin
    if Pos('data:', line) = 1 then
      data := data + Trim(Copy(line, 6, MaxInt))
    else if (line = '') and (data <> '') then
    begin
      if (Pos('"result"', data) > 0) or (Pos('"error"', data) > 0) then Exit(data);
      data := '';
    end;
  end;
  if data <> '' then Result := data;
end;

function TMCPHttpTransport.SendRequest(const AJsonRpcRequest: string): string;
var
  resp: TAIHttpResponse;
begin
  if not FConnected then
    RaiseUDAW(errInvalidState, SUBSYS, 'MCP HTTP transport is not started');
  resp := FHttp.Post(FEndpoint, BuildHeaders, AJsonRpcRequest);
  if (resp.StatusCode < 200) or (resp.StatusCode >= 300) then
    RaiseUDAWFmt(errNetwork, SUBSYS, 'MCP HTTP request to "%s" returned status %d',
      [FEndpoint, resp.StatusCode]);
  Result := ExtractJsonPayload(resp.Body);
end;

procedure TMCPHttpTransport.SendNotification(const AJsonRpcNotification: string);
begin
  if not FConnected then Exit;
  try
    FHttp.Post(FEndpoint, BuildHeaders, AJsonRpcNotification);
  except
    { best-effort - a notification never blocks or raises }
  end;
end;

{ ================= TMCPClient ================= }

constructor TMCPClient.Create;
begin
  inherited Create;
  FNextId := 1;
  FInitialized := False;
end;

function TMCPClient.NextRequestId: Integer;
begin
  Result := FNextId;
  Inc(FNextId);
end;

function TMCPClient.LastRequestId: Integer;
begin
  Result := FLastId;
end;

function TMCPClient.BuildRequest(const AMethod: string; AParams: TJSONValue; AId: Integer): string;
var
  req: TJSONValue;
begin
  req := JSONObject;
  try
    req.AddPair('jsonrpc', JSONString('2.0'));
    req.AddPair('id', JSONNumber(AId));
    req.AddPair('method', JSONString(AMethod));
    if AParams <> nil then
      req.AddPair('params', AParams)
    else
      req.AddPair('params', JSONObject);
    Result := req.ToJSONString;
  finally
    req.Free;
  end;
end;

function TMCPClient.BuildNotification(const AMethod: string; AParams: TJSONValue): string;
var
  req: TJSONValue;
begin
  req := JSONObject;
  try
    req.AddPair('jsonrpc', JSONString('2.0'));
    req.AddPair('method', JSONString(AMethod));
    if AParams <> nil then
      req.AddPair('params', AParams)
    else
      req.AddPair('params', JSONObject);
    Result := req.ToJSONString;
  finally
    req.Free;
  end;
end;

{ Sends AMethod/AParams (AParams ownership passed in - freed by BuildRequest),
  blocks for the matching response, and returns the FULL parsed JSON-RPC
  response object (the caller reads .ByName('result') and must Free the
  returned value). Raises EUDAWError(errNetwork) if the server's response
  itself carries a JSON-RPC "error" member. }
function TMCPClient.SendAndParse(const AMethod: string; AParams: TJSONValue): TJSONValue;
var
  reqText, respText: string;
  errVal, msgVal: TJSONValue;
  errMsg: string;
begin
  if FTransport = nil then
    RaiseUDAW(errInvalidState, SUBSYS, 'MCP client not initialized with a transport');
  FLastId := NextRequestId;
  reqText := BuildRequest(AMethod, AParams, FLastId);
  respText := FTransport.SendRequest(reqText);
  Result := UDAW.AI.JSON.Parse(respText);
  if Result.Kind = jkObject then
  begin
    errVal := Result.ByName('error');
    if errVal <> nil then
    begin
      errMsg := Format('MCP method "%s" failed', [AMethod]);
      if errVal.Kind = jkObject then
      begin
        msgVal := errVal.ByName('message');
        if msgVal <> nil then
          errMsg := Format('MCP method "%s" failed: %s', [AMethod, msgVal.AsString]);
      end;
      Result.Free;
      Result := nil;
      RaiseUDAW(errNetwork, SUBSYS, errMsg);
    end;
  end;
end;

procedure TMCPClient.RequireInitialized;
begin
  if not FInitialized then
    RaiseUDAW(errInvalidState, SUBSYS, 'MCP client has not completed "initialize" with the server');
end;

function TMCPClient.Initialize(ATransport: IMCPTransport): Boolean;
var
  params, capsObj, clientInfo, resp, resultVal, serverCaps, serverInfo, nameVal, verVal: TJSONValue;
begin
  FTransport := ATransport;
  FInitialized := False;
  FLastError := '';
  FillChar(FCaps, SizeOf(FCaps), 0);

  { NOTE: SendAndParse -> BuildRequest unconditionally consumes/frees params
    (FTransport is never nil here - it was just assigned above), so params
    must not be wrapped in its own try/finally: whether SendAndParse
    succeeds or raises, ownership has already passed to BuildRequest by the
    time control leaves this call. }
  params := JSONObject;
  params.AddPair('protocolVersion', JSONString(MCP_PROTOCOL_VERSION));
  capsObj := JSONObject;
  params.AddPair('capabilities', capsObj);
  clientInfo := JSONObject;
  clientInfo.AddPair('name', JSONString('UDAW'));
  clientInfo.AddPair('version', JSONString('1.0'));
  params.AddPair('clientInfo', clientInfo);

  try
    resp := SendAndParse('initialize', params);
  except
    on E: EUDAWError do
    begin
      FLastError := E.Message;
      Exit(False);  // server unreachable/timed out - degrade, do not raise
    end;
  end;

  try
    resultVal := resp.ByName('result');
    if resultVal = nil then
    begin
      FLastError := 'initialize reply has no result';
      Exit(False);
    end;
    serverCaps := resultVal.ByName('capabilities');
    if serverCaps <> nil then
    begin
      FCaps.HasTools := serverCaps.HasName('tools');
      FCaps.HasResources := serverCaps.HasName('resources');
      FCaps.HasPrompts := serverCaps.HasName('prompts');
    end;
    serverInfo := resultVal.ByName('serverInfo');
    if serverInfo <> nil then
    begin
      nameVal := serverInfo.ByName('name');
      verVal := serverInfo.ByName('version');
      if nameVal <> nil then FCaps.ServerName := nameVal.AsString;
      if verVal <> nil then FCaps.ServerVersion := verVal.AsString;
    end;
  finally
    resp.Free;
  end;

  FInitialized := True;
  { fire-and-forget - per spec this has no response, and per the plan's
    availability rule a failure here must never block the handshake result }
  FTransport.SendNotification(BuildNotification('notifications/initialized', nil));
  Result := True;
end;

function TMCPClient.LastError: string;
begin
  Result := FLastError;
end;

function TMCPClient.IsInitialized: Boolean;
begin
  Result := FInitialized;
end;

function TMCPClient.Capabilities: TMCPServerCapabilities;
begin
  Result := FCaps;
end;

function TMCPClient.ListToolsDetailed: TArray<TMCPToolInfo>;
var
  resp, resultVal, toolsVal, toolVal, v: TJSONValue;
  i: Integer;
  list: TArray<TMCPToolInfo>;
  info: TMCPToolInfo;
begin
  RequireInitialized;
  resp := SendAndParse('tools/list', nil);
  try
    SetLength(list, 0);
    resultVal := resp.ByName('result');
    if resultVal = nil then Exit(list);
    toolsVal := resultVal.ByName('tools');
    if (toolsVal = nil) or (toolsVal.Kind <> jkArray) then Exit(list);
    SetLength(list, toolsVal.Count);
    for i := 0 to toolsVal.Count - 1 do
    begin
      FillChar(info, SizeOf(info), 0);
      toolVal := toolsVal.Items[i];
      if (toolVal <> nil) and (toolVal.Kind = jkObject) then
      begin
        v := toolVal.ByName('name');
        if v <> nil then info.Name := v.AsString;
        v := toolVal.ByName('description');
        if v <> nil then info.Description := v.AsString;
        v := toolVal.ByName('inputSchema');
        if v <> nil then info.InputSchemaJson := v.ToJSONString;
      end;
      list[i] := info;
    end;
    Result := list;
  finally
    resp.Free;
  end;
end;

function TMCPClient.ListTools: TArray<string>;
var
  detailed: TArray<TMCPToolInfo>;
  i: Integer;
  names: TArray<string>;
begin
  detailed := ListToolsDetailed;
  SetLength(names, Length(detailed));
  for i := 0 to High(detailed) do
    names[i] := detailed[i].Name;
  Result := names;
end;

function TMCPClient.ListResources: TArray<TMCPResourceInfo>;
var
  resp, resultVal, itemsVal, itemVal, v: TJSONValue;
  i: Integer;
  list: TArray<TMCPResourceInfo>;
  info: TMCPResourceInfo;
begin
  RequireInitialized;
  resp := SendAndParse('resources/list', nil);
  try
    SetLength(list, 0);
    resultVal := resp.ByName('result');
    if resultVal = nil then Exit(list);
    itemsVal := resultVal.ByName('resources');
    if (itemsVal = nil) or (itemsVal.Kind <> jkArray) then Exit(list);
    SetLength(list, itemsVal.Count);
    for i := 0 to itemsVal.Count - 1 do
    begin
      FillChar(info, SizeOf(info), 0);
      itemVal := itemsVal.Items[i];
      if (itemVal <> nil) and (itemVal.Kind = jkObject) then
      begin
        v := itemVal.ByName('uri'); if v <> nil then info.Uri := v.AsString;
        v := itemVal.ByName('name'); if v <> nil then info.Name := v.AsString;
        v := itemVal.ByName('description'); if v <> nil then info.Description := v.AsString;
        v := itemVal.ByName('mimeType'); if v <> nil then info.MimeType := v.AsString;
      end;
      list[i] := info;
    end;
    Result := list;
  finally
    resp.Free;
  end;
end;

function TMCPClient.ReadResource(const AUri: string): string;
var
  params, resp, resultVal, contentsVal, itemVal, v: TJSONValue;
  i: Integer;
  sb: TStringBuilder;
begin
  RequireInitialized;
  params := JSONObject;
  params.AddPair('uri', JSONString(AUri));
  resp := SendAndParse('resources/read', params);
  try
    resultVal := resp.ByName('result');
    if resultVal = nil then Exit('');
    contentsVal := resultVal.ByName('contents');
    if (contentsVal = nil) or (contentsVal.Kind <> jkArray) then Exit('');
    sb := TStringBuilder.Create;
    try
      for i := 0 to contentsVal.Count - 1 do
      begin
        itemVal := contentsVal.Items[i];
        if (itemVal <> nil) and (itemVal.Kind = jkObject) then
        begin
          v := itemVal.ByName('text');
          if v <> nil then
          begin
            if sb.Length > 0 then sb.Append(sLineBreak);
            sb.Append(v.AsString);
          end;
        end;
      end;
      Result := sb.ToString;
    finally
      sb.Free;
    end;
  finally
    resp.Free;
  end;
end;

function TMCPClient.ListPrompts: TArray<TMCPPromptInfo>;
var
  resp, resultVal, itemsVal, itemVal, v: TJSONValue;
  i: Integer;
  list: TArray<TMCPPromptInfo>;
  info: TMCPPromptInfo;
begin
  RequireInitialized;
  resp := SendAndParse('prompts/list', nil);
  try
    SetLength(list, 0);
    resultVal := resp.ByName('result');
    if resultVal = nil then Exit(list);
    itemsVal := resultVal.ByName('prompts');
    if (itemsVal = nil) or (itemsVal.Kind <> jkArray) then Exit(list);
    SetLength(list, itemsVal.Count);
    for i := 0 to itemsVal.Count - 1 do
    begin
      FillChar(info, SizeOf(info), 0);
      itemVal := itemsVal.Items[i];
      if (itemVal <> nil) and (itemVal.Kind = jkObject) then
      begin
        v := itemVal.ByName('name'); if v <> nil then info.Name := v.AsString;
        v := itemVal.ByName('description'); if v <> nil then info.Description := v.AsString;
        v := itemVal.ByName('arguments'); if v <> nil then info.ArgumentsJson := v.ToJSONString;
      end;
      list[i] := info;
    end;
    Result := list;
  finally
    resp.Free;
  end;
end;

function TMCPClient.GetPrompt(const AName: string; const AArgsJson: string): string;
var
  params, argsVal, resp: TJSONValue;
begin
  RequireInitialized;
  params := JSONObject;
  params.AddPair('name', JSONString(AName));
  if Trim(AArgsJson) <> '' then
    argsVal := UDAW.AI.JSON.Parse(AArgsJson)
  else
    argsVal := JSONObject;
  params.AddPair('arguments', argsVal);
  resp := SendAndParse('prompts/get', params);
  try
    if resp.ByName('result') <> nil then
      Result := resp.ByName('result').ToJSONString
    else
      Result := '';
  finally
    resp.Free;
  end;
end;

function TMCPClient.CallTool(const AToolName: string; const AArgsJson: string): string;
var
  params, argsVal, resp, resultVal: TJSONValue;
begin
  RequireInitialized;
  params := JSONObject;
  params.AddPair('name', JSONString(AToolName));
  if Trim(AArgsJson) <> '' then
    argsVal := UDAW.AI.JSON.Parse(AArgsJson)
  else
    argsVal := JSONObject;
  params.AddPair('arguments', argsVal);
  resp := SendAndParse('tools/call', params);
  try
    resultVal := resp.ByName('result');
    if resultVal <> nil then
      Result := resultVal.ToJSONString
    else
      Result := resp.ToJSONString;
  finally
    resp.Free;
  end;
end;

procedure TMCPClient.CancelRequest(ARequestId: Integer);
var
  params: TJSONValue;
begin
  if FTransport = nil then Exit;
  params := JSONObject;
  params.AddPair('requestId', JSONNumber(ARequestId));
  params.AddPair('reason', JSONString('client cancelled'));
  try
    FTransport.SendNotification(BuildNotification('notifications/cancelled', params));
    params := nil;  // ownership transferred into BuildNotification
  finally
    params.Free;
  end;
end;

{ ================= TMCPServerConfig ================= }

class function TMCPServerConfig.Default(const AName: string): TMCPServerConfig;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Name := AName;
  Result.UseStdio := True;
  Result.Enabled := True;
  Result.TimeoutMs := 10000;
end;

{ ================= TMCPServerRegistry ================= }

constructor TMCPServerRegistry.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  SetLength(FItems, 0);
end;

destructor TMCPServerRegistry.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TMCPServerRegistry.IndexOf(const AName: string): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FItems) do
    if SameText(FItems[i].Name, AName) then
      Exit(i);
  Result := -1;
end;

procedure TMCPServerRegistry.Add(const AConfig: TMCPServerConfig);
begin
  if Trim(AConfig.Name) = '' then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'MCP server config needs a non-empty Name');
  FLock.Enter;
  try
    if IndexOf(AConfig.Name) >= 0 then
      RaiseUDAWFmt(errInvalidArgument, SUBSYS, 'an MCP server named "%s" already exists', [AConfig.Name]);
    SetLength(FItems, Length(FItems) + 1);
    FItems[High(FItems)] := AConfig;
  finally
    FLock.Leave;
  end;
end;

procedure TMCPServerRegistry.Update(const AConfig: TMCPServerConfig);
var
  idx: Integer;
begin
  FLock.Enter;
  try
    idx := IndexOf(AConfig.Name);
    if idx < 0 then
      RaiseUDAWFmt(errInvalidArgument, SUBSYS, 'no MCP server named "%s" to update', [AConfig.Name]);
    FItems[idx] := AConfig;
  finally
    FLock.Leave;
  end;
end;

procedure TMCPServerRegistry.Remove(const AName: string);
var
  i, j: Integer;
begin
  FLock.Enter;
  try
    for i := 0 to High(FItems) do
      if SameText(FItems[i].Name, AName) then
      begin
        for j := i to High(FItems) - 1 do
          FItems[j] := FItems[j + 1];
        SetLength(FItems, Length(FItems) - 1);
        Break;
      end;
  finally
    FLock.Leave;
  end;
end;

function TMCPServerRegistry.Count: Integer;
begin
  FLock.Enter;
  try
    Result := Length(FItems);
  finally
    FLock.Leave;
  end;
end;

function TMCPServerRegistry.GetConfig(AIndex: Integer): TMCPServerConfig;
begin
  FLock.Enter;
  try
    Result := FItems[AIndex];
  finally
    FLock.Leave;
  end;
end;

function TMCPServerRegistry.FindByName(const AName: string; out AConfig: TMCPServerConfig): Boolean;
var
  i: Integer;
begin
  FLock.Enter;
  try
    for i := 0 to High(FItems) do
      if SameText(FItems[i].Name, AName) then
      begin
        AConfig := FItems[i];
        Exit(True);
      end;
    Result := False;
  finally
    FLock.Leave;
  end;
end;

{ One line per field, "[server]" / "[/server]" delimited blocks, a single
  "UDAWMCP1" header line - the same hand-written line-oriented style as
  every other UDAW text serializer (graph/mixer/tracker/...), rather than
  pulling in a config-file library for what is a short, UI-edited list.
  Values are kept to a single line (CR/LF stripped on save); AllowedTools is
  comma-joined and Environment is ';'-joined "KEY=VALUE" pairs - adequate
  for the tool names / env var values MCP servers actually use, and not
  meant to be hand-edited outside the app. }
const
  MCP_REGISTRY_HEADER = 'UDAWMCP1';

function MCPSingleLine(const S: string): string;
begin
  Result := StringReplace(StringReplace(S, #13, ' ', [rfReplaceAll]), #10, ' ', [rfReplaceAll]);
end;

procedure TMCPServerRegistry.SaveToFile(const APath: string);
var
  sl: TStringList;
  i, j: Integer;
  cfg: TMCPServerConfig;
  envParts: TArray<string>;
begin
  sl := TStringList.Create;
  try
    sl.Add(MCP_REGISTRY_HEADER);
    FLock.Enter;
    try
      for i := 0 to High(FItems) do
      begin
        cfg := FItems[i];
        sl.Add('[server]');
        sl.Add('name=' + MCPSingleLine(cfg.Name));
        if cfg.UseStdio then sl.Add('type=stdio') else sl.Add('type=http');
        sl.Add('command=' + MCPSingleLine(cfg.CommandLine));
        sl.Add('endpoint=' + MCPSingleLine(cfg.HttpEndpoint));
        sl.Add('enabled=' + IntToStr(Ord(cfg.Enabled)));
        sl.Add('timeout=' + IntToStr(cfg.TimeoutMs));
        sl.Add('allowed=' + MCPSingleLine(string.Join(',', cfg.AllowedTools)));
        SetLength(envParts, Length(cfg.Environment));
        for j := 0 to High(cfg.Environment) do
          envParts[j] := cfg.Environment[j].Name + '=' + cfg.Environment[j].Value;
        sl.Add('env=' + MCPSingleLine(string.Join(';', envParts)));
        sl.Add('[/server]');
      end;
    finally
      FLock.Leave;
    end;
    ForceDirectories(ExtractFilePath(APath));
    sl.SaveToFile(APath, TEncoding.UTF8);
  finally
    sl.Free;
  end;
end;

procedure TMCPServerRegistry.LoadFromFile(const APath: string);
var
  sl: TStringList;
  i, eqPos: Integer;
  line, key, value: string;
  cfg: TMCPServerConfig;
  inBlock: Boolean;
  newItems: TArray<TMCPServerConfig>;
  parts: TArray<string>;
  j: Integer;
  kv: TArray<string>;
begin
  if not FileExists(APath) then Exit;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(APath, TEncoding.UTF8);
    if (sl.Count = 0) or (Trim(sl[0]) <> MCP_REGISTRY_HEADER) then Exit;

    SetLength(newItems, 0);
    inBlock := False;
    cfg := TMCPServerConfig.Default('');
    for i := 1 to sl.Count - 1 do
    begin
      line := sl[i];
      if SameText(Trim(line), '[server]') then
      begin
        cfg := TMCPServerConfig.Default('');
        inBlock := True;
        Continue;
      end;
      if SameText(Trim(line), '[/server]') then
      begin
        if inBlock and (Trim(cfg.Name) <> '') then
        begin
          SetLength(newItems, Length(newItems) + 1);
          newItems[High(newItems)] := cfg;
        end;
        inBlock := False;
        Continue;
      end;
      if not inBlock then Continue;

      eqPos := Pos('=', line);
      if eqPos < 1 then Continue;
      key := Copy(line, 1, eqPos - 1);
      value := Copy(line, eqPos + 1, MaxInt);

      if SameText(key, 'name') then cfg.Name := value
      else if SameText(key, 'type') then cfg.UseStdio := SameText(value, 'stdio')
      else if SameText(key, 'command') then cfg.CommandLine := value
      else if SameText(key, 'endpoint') then cfg.HttpEndpoint := value
      else if SameText(key, 'enabled') then cfg.Enabled := (value = '1')
      else if SameText(key, 'timeout') then cfg.TimeoutMs := StrToIntDef(value, 10000)
      else if SameText(key, 'allowed') then
      begin
        if Trim(value) = '' then
          SetLength(cfg.AllowedTools, 0)
        else
          cfg.AllowedTools := value.Split([',']);
      end
      else if SameText(key, 'env') then
      begin
        SetLength(cfg.Environment, 0);
        if Trim(value) <> '' then
        begin
          parts := value.Split([';']);
          SetLength(cfg.Environment, Length(parts));
          for j := 0 to High(parts) do
          begin
            kv := parts[j].Split(['='], 2);
            cfg.Environment[j].Name := kv[0];
            if Length(kv) > 1 then cfg.Environment[j].Value := kv[1];
          end;
        end;
      end;
    end;

    FLock.Enter;
    try
      FItems := newItems;
    finally
      FLock.Leave;
    end;
  finally
    sl.Free;
  end;
end;

procedure TMCPServerRegistry.Save;
begin
  SaveToFile(MCPDefaultRegistryPath);
end;

procedure TMCPServerRegistry.Load;
begin
  LoadFromFile(MCPDefaultRegistryPath);
end;

var
  GMCPServerRegistry: TMCPServerRegistry;

function MCPServerRegistry: TMCPServerRegistry;
begin
  if GMCPServerRegistry = nil then
  begin
    GMCPServerRegistry := TMCPServerRegistry.Create;
    try
      GMCPServerRegistry.Load;
    except
      { a corrupt/unreadable config file must never prevent the DAW from
        starting - it just starts with an empty MCP server list }
    end;
  end;
  Result := GMCPServerRegistry;
end;

function MCPDefaultRegistryPath: string;
begin
  Result := UDAW.Paths.ConfigFile('mcp_servers.cfg');
end;

initialization

finalization
  FreeAndNil(GMCPServerRegistry);

end.
