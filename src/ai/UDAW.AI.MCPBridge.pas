unit UDAW.AI.MCPBridge;
{$I udaw.inc}

{ Phase 26 - TMCPToolBridge: wires the MCP servers a user has configured in
  TMCPServerRegistry into the AI chat loop, alongside (not instead of) the
  built-in DAW tool vocabulary in UDAW.AI.ToolCommands.

  Design choice, and why: UDAW.AI.ToolCommands' fenced ```tool blocks are
  DAW COMMANDS - every one of them maps onto a real, validated TDAWCommand
  (SetGain, AddTrack, ...), so it is safe to execute them automatically
  (subject to the existing destructive-tool confirmation prompt). An MCP
  tool is arbitrary and external (a sample librarian, a docs server, a
  project-management server) - UDAW has no idea what "delete_all_files"
  might do on someone's filesystem-MCP-server. So this bridge treats every
  MCP tool call as READ/INFORMATIONAL from the DAW's point of view: the
  result text is fed back to the model as additional context, but nothing
  an MCP tool returns is ever turned into a DAW mutation by this unit. The
  plan's "every MCP tool result still passes through Command Validation
  before any DAW mutation" is satisfied trivially - this bridge performs no
  DAW mutation at all; if a later reply also emits a ```tool block, THAT
  goes through TAIToolDispatcher exactly like any other AI turn.

  Privacy gating (plan section 43, "AI Privacy System") does not exist yet
  in this codebase - when it lands, BuildSystemPromptFragment/Execute are
  the two places to consult it before a tool listing/call leaves the
  process. Until then, only the per-server Enabled flag and per-server
  AllowedTools allow-list gate what is reachable. }

interface

uses
  SysUtils, Generics.Collections,
  UDAW.Errors, UDAW.AI.JSON, UDAW.AI.SecureLog, UDAW.AI.MCP, UDAW.AI.Credentials;

type
  TMCPToolCallRequest = record
    ServerName: string;
    ToolName: string;
    ArgumentsJson: string;
  end;

  { One connected server: transport + client + its last-known tool list.
    Kept alive for the lifetime of the bridge (normally the lifetime of the
    AI chat session) so repeated tool calls in one conversation don't pay
    the process-launch/handshake cost every time. }
  TMCPConnectedServer = class
  public
    Config: TMCPServerConfig;
    Transport: IMCPTransport;
    Client: IMCPClient;
    Tools: TArray<TMCPToolInfo>;
    Connected: Boolean;
    LastError: string;
  end;

  TMCPToolBridge = class
  private
    FServers: TObjectList<TMCPConnectedServer>;
    function FindServer(const AName: string): TMCPConnectedServer;
    function EnsureConnected(const AConfig: TMCPServerConfig): TMCPConnectedServer;
    function IsToolAllowed(AServer: TMCPConnectedServer; const AToolName: string): Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    { Connects to every enabled, currently-reachable server in
      MCPServerRegistry and refreshes its tool list. Never raises - a
      server that fails to start/handshake is recorded (LastError) and
      simply contributes no tools, per the plan's "degrades to unavailable"
      rule. Safe to call again to pick up registry changes. }
    procedure RefreshAll;

    { True if at least one connected server has at least one tool - callers
      use this to decide whether to bother appending the system-prompt
      fragment / parsing replies for mcp-tool blocks at all. }
    function HasAnyTools: Boolean;

    { Appended to the AI system message alongside AIToolSystemPrompt (see
      UDAW.AI.ToolCommands), describing every externally discovered MCP
      tool as a distinct ```mcp-tool fenced-block command so the model can
      tell UDAW's own DAW commands and MCP tools apart at a glance. Empty
      string if no server currently has any tools. }
    function BuildSystemPromptFragment: string;

    { Every well-formed ```mcp-tool fenced JSON block (server/tool/arguments)
      found in AText, in order. Malformed/unrecognised blocks are skipped,
      matching ParseAIToolCalls' tolerance for free-form chat text around
      the fenced blocks. }
    function ParseMCPToolCalls(const AText: string): TArray<TMCPToolCallRequest>;

    { Executes one call. Returns True and the tool's raw JSON/text result in
      AResultText on success; False and an explanatory AResultText (never an
      exception) on any failure - unknown server, disabled server, tool not
      in that server's allow-list, transport/protocol error. }
    function Execute(const ACall: TMCPToolCallRequest; out AResultText: string): Boolean;

    procedure DisconnectAll;
  end;

implementation

const
  SUBSYS = 'AI.MCPBridge';

{ ================= TMCPToolBridge ================= }

constructor TMCPToolBridge.Create;
begin
  inherited Create;
  FServers := TObjectList<TMCPConnectedServer>.Create(True);
end;

destructor TMCPToolBridge.Destroy;
begin
  DisconnectAll;
  FServers.Free;
  inherited Destroy;
end;

procedure TMCPToolBridge.DisconnectAll;
var
  i: Integer;
begin
  for i := 0 to FServers.Count - 1 do
  begin
    try
      if FServers[i].Transport <> nil then
        FServers[i].Transport.Stop;
    except
      { best-effort teardown }
    end;
  end;
  FServers.Clear;
end;

function TMCPToolBridge.FindServer(const AName: string): TMCPConnectedServer;
var
  i: Integer;
begin
  for i := 0 to FServers.Count - 1 do
    if SameText(FServers[i].Config.Name, AName) then
      Exit(FServers[i]);
  Result := nil;
end;

function TMCPToolBridge.EnsureConnected(const AConfig: TMCPServerConfig): TMCPConnectedServer;
var
  entry: TMCPConnectedServer;
  stdio: TMCPStdioTransport;
  http: TMCPHttpTransport;
  envArr: TArray<TMCPEnvVar>;
  i: Integer;
  token: string;
begin
  entry := FindServer(AConfig.Name);
  if entry = nil then
  begin
    entry := TMCPConnectedServer.Create;
    entry.Config := AConfig;
    FServers.Add(entry);
  end
  else
    entry.Config := AConfig;   // pick up any edited settings (timeout, allow-list, ...)

  if entry.Connected then
    Exit(entry);

  entry.LastError := '';
  try
    if AConfig.UseStdio then
    begin
      stdio := TMCPStdioTransport.Create;
      stdio.CommandLine := AConfig.CommandLine;
      if AConfig.TimeoutMs > 0 then
        stdio.TimeoutMs := AConfig.TimeoutMs;
      { SetLength/indexed-write cannot target a property directly (it needs
        an addressable variable) - build the array separately and assign it
        to the property as one whole-array copy instead. }
      SetLength(envArr, Length(AConfig.Environment));
      for i := 0 to High(AConfig.Environment) do
        envArr[i] := AConfig.Environment[i];
      stdio.Environment := envArr;
      entry.Transport := stdio;
    end
    else
    begin
      http := TMCPHttpTransport.Create;
      http.Endpoint := AConfig.HttpEndpoint;
      if GetMCPClientToken(AConfig.Name, token) then
        http.BearerToken := token;   // credential comes from the OS secure store, never the registry file
      entry.Transport := http;
    end;

    entry.Transport.Start;
    entry.Client := TMCPClient.Create;
    if not entry.Client.Initialize(entry.Transport) then
    begin
      entry.LastError := 'server did not complete the MCP handshake';
      entry.Transport.Stop;
      entry.Transport := nil;
      entry.Client := nil;
      Exit(entry);
    end;

    entry.Tools := entry.Client.ListToolsDetailed;
    entry.Connected := True;
    AISecureLog.Info(SUBSYS, Format('MCP server "%s" connected (%d tool(s))',
      [AConfig.Name, Length(entry.Tools)]));
  except
    on E: Exception do
    begin
      entry.LastError := E.Message;
      entry.Connected := False;
      if entry.Transport <> nil then
        try entry.Transport.Stop; except end;
      entry.Transport := nil;
      entry.Client := nil;
      AISecureLog.Warn(SUBSYS, Format('MCP server "%s" unavailable: %s', [AConfig.Name, E.Message]));
    end;
  end;
  Result := entry;
end;

procedure TMCPToolBridge.RefreshAll;
var
  i: Integer;
  cfg: TMCPServerConfig;
begin
  for i := 0 to MCPServerRegistry.Count - 1 do
  begin
    cfg := MCPServerRegistry.GetConfig(i);
    if not cfg.Enabled then Continue;
    EnsureConnected(cfg);
  end;
end;

function TMCPToolBridge.HasAnyTools: Boolean;
var
  i: Integer;
begin
  for i := 0 to FServers.Count - 1 do
    if FServers[i].Connected and (Length(FServers[i].Tools) > 0) then
      Exit(True);
  Result := False;
end;

function TMCPToolBridge.IsToolAllowed(AServer: TMCPConnectedServer; const AToolName: string): Boolean;
var
  i: Integer;
begin
  if Length(AServer.Config.AllowedTools) = 0 then
    Exit(True);   // empty allow-list = every advertised tool may be called
  for i := 0 to High(AServer.Config.AllowedTools) do
    if SameText(AServer.Config.AllowedTools[i], AToolName) then
      Exit(True);
  Result := False;
end;

function TMCPToolBridge.BuildSystemPromptFragment: string;
var
  sb: TStringBuilder;
  i, j: Integer;
  srv: TMCPConnectedServer;
  tool: TMCPToolInfo;
  any: Boolean;
begin
  any := False;
  sb := TStringBuilder.Create;
  try
    sb.Append('In addition to the DAW tool commands above, the following external MCP ' +
      'tools are available (from user-configured MCP servers). Call one with a fenced ' +
      'block: ```mcp-tool' + sLineBreak +
      '{"server":"<server name>","tool":"<tool name>","arguments":{...}}' + sLineBreak +
      '``` The result is returned to you as context only - it never directly changes the ' +
      'project; use a DAW tool command afterwards if the user wants that context acted on. ' +
      'Available MCP tools:' + sLineBreak);
    for i := 0 to FServers.Count - 1 do
    begin
      srv := FServers[i];
      if not srv.Connected then Continue;
      for j := 0 to High(srv.Tools) do
      begin
        tool := srv.Tools[j];
        if not IsToolAllowed(srv, tool.Name) then Continue;
        any := True;
        sb.Append(Format('- server "%s", tool "%s"', [srv.Config.Name, tool.Name]));
        if Trim(tool.Description) <> '' then
          sb.Append(': ').Append(tool.Description);
        sb.Append(sLineBreak);
      end;
    end;
    if any then
      Result := sb.ToString
    else
      Result := '';
  finally
    sb.Free;
  end;
end;

function TMCPToolBridge.ParseMCPToolCalls(const AText: string): TArray<TMCPToolCallRequest>;
const
  FENCE_OPEN = '```mcp-tool';
  FENCE_CLOSE = '```';
var
  list: TList<TMCPToolCallRequest>;
  pos, openAt, bodyStart, closeAt: Integer;
  body: string;
  v, serverVal, toolVal, argsVal: TJSONValue;
  call: TMCPToolCallRequest;
begin
  list := TList<TMCPToolCallRequest>.Create;
  try
    pos := 1;
    while True do
    begin
      openAt := System.Pos(FENCE_OPEN, AText, pos);
      if openAt = 0 then Break;
      bodyStart := openAt + Length(FENCE_OPEN);
      closeAt := System.Pos(FENCE_CLOSE, AText, bodyStart);
      if closeAt = 0 then Break;
      body := Trim(Copy(AText, bodyStart, closeAt - bodyStart));
      pos := closeAt + Length(FENCE_CLOSE);

      try
        v := UDAW.AI.JSON.Parse(body);
      except
        Continue;
      end;
      try
        if (v = nil) or (v.Kind <> jkObject) then Continue;
        serverVal := v.ByName('server');
        toolVal := v.ByName('tool');
        if (serverVal = nil) or (serverVal.Kind <> jkString) then Continue;
        if (toolVal = nil) or (toolVal.Kind <> jkString) then Continue;
        call.ServerName := serverVal.AsString;
        call.ToolName := toolVal.AsString;
        argsVal := v.ByName('arguments');
        if argsVal <> nil then
          call.ArgumentsJson := argsVal.ToJSONString
        else
          call.ArgumentsJson := '{}';
        list.Add(call);
      finally
        v.Free;
      end;
    end;
    Result := list.ToArray;
  finally
    list.Free;
  end;
end;

function TMCPToolBridge.Execute(const ACall: TMCPToolCallRequest; out AResultText: string): Boolean;
var
  cfg: TMCPServerConfig;
  entry: TMCPConnectedServer;
begin
  Result := False;
  if not MCPServerRegistry.FindByName(ACall.ServerName, cfg) then
  begin
    AResultText := Format('no MCP server named "%s" is configured', [ACall.ServerName]);
    Exit;
  end;
  if not cfg.Enabled then
  begin
    AResultText := Format('MCP server "%s" is disabled', [ACall.ServerName]);
    Exit;
  end;

  entry := EnsureConnected(cfg);
  if not entry.Connected then
  begin
    AResultText := Format('MCP server "%s" is unavailable: %s', [ACall.ServerName, entry.LastError]);
    Exit;
  end;
  if not IsToolAllowed(entry, ACall.ToolName) then
  begin
    AResultText := Format('tool "%s" is not in the allow-list for MCP server "%s"',
      [ACall.ToolName, ACall.ServerName]);
    Exit;
  end;

  try
    AResultText := entry.Client.CallTool(ACall.ToolName, ACall.ArgumentsJson);
    Result := True;
  except
    on E: Exception do
    begin
      AResultText := Format('MCP tool "%s.%s" failed: %s', [ACall.ServerName, ACall.ToolName, E.Message]);
      Result := False;
    end;
  end;
end;

end.
