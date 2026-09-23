unit Tests.Phase26MCP;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}

{ Phase 26 acceptance tests - the MCP layer additions beyond Phase 20's
  in-memory-only registry (see Tests.Phase20 for the original add/find/
  remove coverage): registry persistence to disk, TMCPToolBridge's
  ```mcp-tool fenced-block parsing, and TUDAWMcpServer's JSON-RPC dispatch
  exercised directly (HandleRequestForTest) - no child process, no real
  socket, matching Tests.Phase20's "no network / no child process" policy
  for this layer. }

interface

procedure RegisterPhase26MCPTests;

implementation

uses
  SysUtils, Classes,
  UDAW.Testing,
  UDAW.AI.JSON,
  UDAW.AI.MCP,
  UDAW.AI.MCPBridge,
  UDAW.AI.MCPServer, UDAW.AI.MCPTls, UDAW.AI.MCPDiag,
  UDAW.AI.MusicTab,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Mixer.Model;

const
  GRP = 'phase26.mcp';

{ ---------------- TMCPServerRegistry persistence ---------------- }

procedure Test_Registry_SaveLoad_RoundTrip;
var
  reg1, reg2: TMCPServerRegistry;
  cfg: TMCPServerConfig;
  found: TMCPServerConfig;
  path: string;
begin
  path := IncludeTrailingPathDelimiter(GetCurrentDir) + 'mcp_registry_test.cfg';
  if FileExists(path) then DeleteFile(path);

  reg1 := TMCPServerRegistry.Create;
  try
    cfg := TMCPServerConfig.Default('local-fs');
    cfg.CommandLine := 'mcp-fs-server --root .';
    cfg.UseStdio := True;
    cfg.Enabled := True;
    cfg.TimeoutMs := 5000;
    cfg.AllowedTools := ['read_file', 'list_dir'];
    SetLength(cfg.Environment, 1);
    cfg.Environment[0].Name := 'FS_ROOT';
    cfg.Environment[0].Value := 'C:\data';
    reg1.Add(cfg);

    cfg := TMCPServerConfig.Default('remote-tools');
    cfg.UseStdio := False;
    cfg.HttpEndpoint := 'https://example.invalid/mcp';
    cfg.Enabled := False;
    reg1.Add(cfg);

    reg1.SaveToFile(path);
  finally
    reg1.Free;
  end;

  reg2 := TMCPServerRegistry.Create;
  try
    reg2.LoadFromFile(path);
    CheckEqualInt(2, reg2.Count, 'both servers reloaded');

    Check(reg2.FindByName('local-fs', found), 'local-fs reloaded');
    Check(found.UseStdio, 'stdio flag survives');
    CheckEqualStr('mcp-fs-server --root .', found.CommandLine, 'command line survives');
    Check(found.Enabled, 'enabled flag survives');
    CheckEqualInt(5000, found.TimeoutMs, 'timeout survives');
    CheckEqualInt(2, Length(found.AllowedTools), 'allow-list survives');
    CheckEqualStr('read_file', found.AllowedTools[0], 'allow-list entry 0');
    CheckEqualStr('list_dir', found.AllowedTools[1], 'allow-list entry 1');
    CheckEqualInt(1, Length(found.Environment), 'env var survives');
    CheckEqualStr('FS_ROOT', found.Environment[0].Name, 'env var name');
    CheckEqualStr('C:\data', found.Environment[0].Value, 'env var value');

    Check(reg2.FindByName('remote-tools', found), 'remote-tools reloaded');
    CheckFalse(found.UseStdio, 'http flag survives');
    CheckEqualStr('https://example.invalid/mcp', found.HttpEndpoint, 'endpoint survives');
    CheckFalse(found.Enabled, 'disabled flag survives');
  finally
    reg2.Free;
  end;

  DeleteFile(path);
end;

procedure Test_Registry_AddDuplicateName_Rejected;
var
  reg: TMCPServerRegistry;
  cfg: TMCPServerConfig;
  raised: Boolean;
begin
  reg := TMCPServerRegistry.Create;
  try
    cfg := TMCPServerConfig.Default('dup');
    reg.Add(cfg);
    raised := False;
    try
      reg.Add(cfg);
    except
      raised := True;
    end;
    Check(raised, 'adding the same server name twice raises');
    CheckEqualInt(1, reg.Count, 'still just one entry');
  finally
    reg.Free;
  end;
end;

procedure Test_Registry_Update_ChangesInPlace;
var
  reg: TMCPServerRegistry;
  cfg, found: TMCPServerConfig;
begin
  reg := TMCPServerRegistry.Create;
  try
    cfg := TMCPServerConfig.Default('srv');
    cfg.TimeoutMs := 1000;
    reg.Add(cfg);

    cfg.TimeoutMs := 9000;
    reg.Update(cfg);

    Check(reg.FindByName('srv', found), 'still found after update');
    CheckEqualInt(9000, found.TimeoutMs, 'timeout was updated in place');
    CheckEqualInt(1, reg.Count, 'update does not duplicate the entry');
  finally
    reg.Free;
  end;
end;

{ ---------------- TMCPToolBridge parsing ---------------- }

procedure Test_MCPBridge_ParseMCPToolCalls_ExtractsFencedBlock;
var
  bridge: TMCPToolBridge;
  calls: TArray<TMCPToolCallRequest>;
begin
  bridge := TMCPToolBridge.Create;
  try
    calls := bridge.ParseMCPToolCalls(
      'Let me check the sample library.' + sLineBreak +
      '```mcp-tool' + sLineBreak +
      '{"server":"samples","tool":"search","arguments":{"query":"kick drum"}}' + sLineBreak +
      '```' + sLineBreak +
      'One moment.');
    CheckEqualInt(1, Length(calls), 'one mcp-tool block found');
    CheckEqualStr('samples', calls[0].ServerName, 'server name parsed');
    CheckEqualStr('search', calls[0].ToolName, 'tool name parsed');
    Check(Pos('kick drum', calls[0].ArgumentsJson) > 0, 'arguments carried through as JSON text');
  finally
    bridge.Free;
  end;
end;

procedure Test_MCPBridge_ParseMCPToolCalls_MalformedSkipped;
var
  bridge: TMCPToolBridge;
  calls: TArray<TMCPToolCallRequest>;
begin
  bridge := TMCPToolBridge.Create;
  try
    calls := bridge.ParseMCPToolCalls(
      '```mcp-tool' + sLineBreak + 'not json' + sLineBreak + '```' + sLineBreak +
      '```mcp-tool' + sLineBreak + '{"tool":"missing-server-field"}' + sLineBreak + '```' + sLineBreak +
      '```mcp-tool' + sLineBreak + '{"server":"ok","tool":"fine"}' + sLineBreak + '```');
    CheckEqualInt(1, Length(calls), 'only the well-formed block survives');
    CheckEqualStr('ok', calls[0].ServerName, 'the valid block was the last one');
  finally
    bridge.Free;
  end;
end;

procedure Test_MCPBridge_Execute_UnknownServer_FailsCleanly;
var
  bridge: TMCPToolBridge;
  call: TMCPToolCallRequest;
  resultText: string;
  ok: Boolean;
begin
  bridge := TMCPToolBridge.Create;
  try
    call.ServerName := 'does-not-exist';
    call.ToolName := 'whatever';
    call.ArgumentsJson := '{}';
    ok := bridge.Execute(call, resultText);
    CheckFalse(ok, 'unknown server => False, not an exception');
    Check(resultText <> '', 'explains why it failed');
  finally
    bridge.Free;
  end;
end;

{ ---------------- TUDAWMcpServer JSON-RPC dispatch ---------------- }

var
  GServerTestDoc: TProjectDocument;
  GServerTestCmds: TCommandManager;

type
  { OnGetDoc/OnGetCommands are "of object" method-pointer properties (they're
    normally bound to a live host's method), so the test double needs to be a
    method too - a plain global function isn't assignment-compatible. }
  TMcpServerTestHost = class
    function GetDoc: TProjectDocument;
    function GetCommands: TCommandManager;
  end;

function TMcpServerTestHost.GetDoc: TProjectDocument;
begin
  Result := GServerTestDoc;
end;

function TMcpServerTestHost.GetCommands: TCommandManager;
begin
  Result := GServerTestCmds;
end;

var
  GMcpTestHost: TMcpServerTestHost;

procedure Test_McpServer_ToolsList_IncludesKnownTools;
var
  server: TUDAWMcpServer;
  respText: string;
  resp, resultVal, toolsVal: TJSONValue;
  i: Integer;
  sawGetProjectInfo: Boolean;
begin
  server := TUDAWMcpServer.Create;
  try
    respText := server.HandleRequestForTest('{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
    resp := UDAW.AI.JSON.Parse(respText);
    try
      resultVal := resp.ByName('result');
      Check(resultVal <> nil, 'result present');
      toolsVal := resultVal.ByName('tools');
      Check((toolsVal <> nil) and (toolsVal.Kind = jkArray), 'tools array present');
      sawGetProjectInfo := False;
      for i := 0 to toolsVal.Count - 1 do
        if toolsVal.Items[i].ByName('name').AsString = 'GetProjectInfo' then
          sawGetProjectInfo := True;
      Check(sawGetProjectInfo, 'GetProjectInfo is advertised');
    finally
      resp.Free;
    end;
  finally
    server.Free;
  end;
end;

procedure Test_McpServer_ToolsList_HasRealSchemas;
var
  server: TUDAWMcpServer;
  resp, toolsVal, t, req: TJSONValue;
  i: Integer;
  sawSplit: Boolean;
begin
  server := TUDAWMcpServer.Create;
  try
    resp := UDAW.AI.JSON.Parse(server.HandleRequestForTest('{"jsonrpc":"2.0","id":1,"method":"tools/list"}'));
    try
      toolsVal := resp.ByName('result').ByName('tools');
      sawSplit := False;
      for i := 0 to toolsVal.Count - 1 do
      begin
        t := toolsVal.Items[i];
        if t.ByName('name').AsString = 'SplitClip' then
        begin
          sawSplit := True;
          req := t.ByName('inputSchema').ByName('required');
          Check((req <> nil) and (req.Count = 2), 'SplitClip requires clip_id + position_sec');
          Check(t.ByName('inputSchema').ByName('properties').ByName('clip_id') <> nil, 'clip_id property published');
        end;
      end;
      Check(sawSplit, 'SplitClip advertised');
    finally
      resp.Free;
    end;
  finally
    server.Free;
  end;
end;

procedure Test_MusicTab_BuildsValidPdf;
var
  pdf, body: string;
  i, xrefAt: Integer;
begin
  body := '';
  for i := 1 to 250 do
    body := body + 'e|--0--3--(5)--|' + sLineBreak;   // parens must be escaped; 250 lines force >1 page
  pdf := BuildTextPdf('Practice', 'sub', body);
  Check(Copy(pdf, 1, 8) = '%PDF-1.4', 'header');
  Check(Pos('/Count 4', pdf) > 0, 'paginated across pages');
  Check(Pos('\(5\)', pdf) > 0, 'parentheses escaped');
  Check(Pos('%%EOF', pdf) > 0, 'trailer present');
  xrefAt := StrToIntDef(Trim(Copy(pdf, Pos('startxref', pdf) + 9, Pos('%%EOF', pdf) - Pos('startxref', pdf) - 9)), -1);
  Check(Copy(pdf, xrefAt + 1, 4) = 'xref', 'startxref points at the xref table');
end;

procedure Test_MusicTab_FileStemAndFences;
begin
  Check(MusicTabFileStem('Blues in A: 12-bar!') = 'Blues_in_A_12_bar', 'stem sanitised');
  Check(MusicTabFileStem('???') = 'music_tab', 'empty stem falls back');
  CheckFalse(Pos('```', MusicTabStripFences('```' + sLineBreak + 'e|-0-|' + sLineBreak + '```')) > 0, 'fences removed');
end;

procedure Test_McpServer_Auth_BearerToken;
var
  server: TUDAWMcpServer;
begin
  server := TUDAWMcpServer.Create;
  try
    Check(server.IsAuthorized(''), 'no token configured = open (loopback only)');
    server.AuthToken := 'secret123';
    CheckFalse(server.IsAuthorized(''), 'missing header refused');
    CheckFalse(server.IsAuthorized('Bearer wrong'), 'wrong token refused');
    CheckFalse(server.IsAuthorized('Bearer secret1234'), 'longer token refused');
    Check(server.IsAuthorized('Bearer secret123'), 'correct token accepted');
  finally
    server.Free;
  end;
end;

procedure Test_McpServer_ToolsCall_ReadOnly_WorksWithoutDestructiveFlag;
var
  server: TUDAWMcpServer;
  respText: string;
  resp, resultVal, contentVal, textItem: TJSONValue;
begin
  GServerTestDoc := TProjectDocument.CreateNew;
  GServerTestCmds := TCommandManager.Create;
  server := TUDAWMcpServer.Create;
  try
    server.OnGetDoc := GMcpTestHost.GetDoc;
    server.OnGetCommands := GMcpTestHost.GetCommands;
    server.AllowDestructive := False;

    respText := server.HandleRequestForTest(
      '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"GetProjectInfo","arguments":{}}}');
    resp := UDAW.AI.JSON.Parse(respText);
    try
      resultVal := resp.ByName('result');
      Check(resultVal <> nil, 'result present for a read-only tool call');
      CheckFalse(resultVal.ByName('isError').AsBool, 'read-only tool call is not an error');
      contentVal := resultVal.ByName('content');
      Check((contentVal <> nil) and (contentVal.Kind = jkArray) and (contentVal.Count = 1), 'one content item');
      textItem := contentVal.Items[0];
      Check(Pos('tempo_bpm', textItem.ByName('text').AsString) > 0, 'GetProjectInfo JSON came back');
    finally
      resp.Free;
    end;
  finally
    server.Free;
    GServerTestCmds.Free;
    GServerTestDoc.Free;
  end;
end;

procedure Test_McpServer_ToolsCall_Destructive_RefusedWithoutAllowFlag;
var
  server: TUDAWMcpServer;
  respText: string;
  resp, resultVal: TJSONValue;
begin
  GServerTestDoc := TProjectDocument.CreateNew;
  GServerTestCmds := TCommandManager.Create;
  server := TUDAWMcpServer.Create;
  try
    server.OnGetDoc := GMcpTestHost.GetDoc;
    server.OnGetCommands := GMcpTestHost.GetCommands;
    server.AllowDestructive := False;   // default, spelled out for clarity

    respText := server.HandleRequestForTest(
      '{"jsonrpc":"2.0","id":3,"method":"tools/call",' +
      '"params":{"name":"AddTrack","arguments":{"track":"New Track"}}}');
    resp := UDAW.AI.JSON.Parse(respText);
    try
      resultVal := resp.ByName('result');
      Check((resultVal <> nil) and resultVal.ByName('isError').AsBool,
        'destructive tool refused when AllowDestructive is off');
    finally
      resp.Free;
    end;
    CheckEqualInt(0, GServerTestDoc.Timeline.TrackCount, 'no track was actually added');
  finally
    server.Free;
    GServerTestCmds.Free;
    GServerTestDoc.Free;
  end;
end;

procedure Test_McpServer_ToolsCall_Destructive_RequiresConfirmEvenWhenAllowed;
var
  server: TUDAWMcpServer;
  respText: string;
  resp, resultVal: TJSONValue;
begin
  GServerTestDoc := TProjectDocument.CreateNew;
  GServerTestCmds := TCommandManager.Create;
  server := TUDAWMcpServer.Create;
  try
    server.OnGetDoc := GMcpTestHost.GetDoc;
    server.OnGetCommands := GMcpTestHost.GetCommands;
    server.AllowDestructive := True;

    { first call: allowed server-side, but no confirm flag - must still refuse }
    respText := server.HandleRequestForTest(
      '{"jsonrpc":"2.0","id":4,"method":"tools/call",' +
      '"params":{"name":"AddTrack","arguments":{"track":"New Track"}}}');
    resp := UDAW.AI.JSON.Parse(respText);
    try
      resultVal := resp.ByName('result');
      Check((resultVal <> nil) and resultVal.ByName('isError').AsBool,
        'destructive tool still refused without arguments.confirm');
    finally
      resp.Free;
    end;
    CheckEqualInt(0, GServerTestDoc.Timeline.TrackCount, 'no track added without confirm');

    { second call: allowed + confirmed - must succeed and actually add the track }
    respText := server.HandleRequestForTest(
      '{"jsonrpc":"2.0","id":5,"method":"tools/call",' +
      '"params":{"name":"AddTrack","arguments":{"track":"New Track","confirm":true}}}');
    resp := UDAW.AI.JSON.Parse(respText);
    try
      resultVal := resp.ByName('result');
      CheckFalse(resultVal.ByName('isError').AsBool, 'confirmed destructive tool succeeds');
    finally
      resp.Free;
    end;
    CheckEqualInt(1, GServerTestDoc.Timeline.TrackCount, 'track was added via the undo-safe dispatcher');
    Check(GServerTestCmds.CanUndo, 'the AddTrack went through the normal undo stack');
  finally
    server.Free;
    GServerTestCmds.Free;
    GServerTestDoc.Free;
  end;
end;

procedure Test_McpServer_UnknownMethod_ReturnsJsonRpcError;
var
  server: TUDAWMcpServer;
  respText: string;
  resp, errVal: TJSONValue;
begin
  server := TUDAWMcpServer.Create;
  try
    respText := server.HandleRequestForTest('{"jsonrpc":"2.0","id":6,"method":"nonsense/method"}');
    resp := UDAW.AI.JSON.Parse(respText);
    try
      errVal := resp.ByName('error');
      Check(errVal <> nil, 'unknown method produces a JSON-RPC error, not a crash');
    finally
      resp.Free;
    end;
  finally
    server.Free;
  end;
end;

procedure Test_McpServer_Notification_GetsNoResponseBody;
var
  server: TUDAWMcpServer;
begin
  server := TUDAWMcpServer.Create;
  try
    CheckEqualStr('', server.HandleRequestForTest(
      '{"jsonrpc":"2.0","method":"notifications/initialized"}'),
      'a notification (no id) produces no response body');
  finally
    server.Free;
  end;
end;

procedure Test_McpServer_Ping_And_StringId_Echoed;
var
  server: TUDAWMcpServer;
  resp: TJSONValue;
begin
  server := TUDAWMcpServer.Create;
  try
    resp := UDAW.AI.JSON.Parse(server.HandleRequestForTest(
      '{"jsonrpc":"2.0","id":"abc-1","method":"ping"}'));
    try
      Check(resp.ByName('error') = nil, 'ping is answered, not an error');
      Check(resp.ByName('result') <> nil, 'ping has a result');
      Check(resp.ByName('id').Kind = jkString, 'string id stays a string');
      CheckEqualStr('abc-1', resp.ByName('id').AsString, 'string id echoed verbatim');
    finally
      resp.Free;
    end;
  finally
    server.Free;
  end;
end;

procedure Test_McpServer_Initialize_NegotiatesProtocolVersion;
var
  server: TUDAWMcpServer;
  resp: TJSONValue;
begin
  server := TUDAWMcpServer.Create;
  try
    resp := UDAW.AI.JSON.Parse(server.HandleRequestForTest(
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}'));
    try
      CheckEqualStr('2025-03-26', resp.ByName('result').ByName('protocolVersion').AsString,
        'a supported client version is echoed');
    finally
      resp.Free;
    end;
    resp := UDAW.AI.JSON.Parse(server.HandleRequestForTest(
      '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}'));
    try
      CheckEqualStr('2025-06-18', resp.ByName('result').ByName('protocolVersion').AsString,
        'an unknown client version gets the newest supported one');
    finally
      resp.Free;
    end;
  finally
    server.Free;
  end;
end;

procedure Test_McpServer_OriginGuard;
var
  server: TUDAWMcpServer;
begin
  server := TUDAWMcpServer.Create;
  try
    Check(server.IsOriginAllowed('http://localhost:3000'), 'localhost origin allowed');
    Check(server.IsOriginAllowed('http://127.0.0.1'), 'loopback origin allowed');
    CheckFalse(server.IsOriginAllowed('https://evil.example.com'), 'foreign origin refused on loopback');
    server.BindAddress := '0.0.0.0';
    Check(server.IsOriginAllowed('https://evil.example.com'), 'off-loopback: bearer token is the gate');
  finally
    server.Free;
  end;
end;

procedure Test_McpHttp_ExtractJsonPayload_HandlesSse;
begin
  CheckEqualStr('{"a":1}', TMCPHttpTransport.ExtractJsonPayload('{"a":1}'), 'bare JSON passes through');
  CheckEqualStr('{"jsonrpc":"2.0","id":1,"result":{}}',
    TMCPHttpTransport.ExtractJsonPayload(
      'event: message'#13#10'data: {"jsonrpc":"2.0","id":1,"result":{}}'#13#10#13#10),
    'SSE message event unwrapped');
end;

{ ---------------- End-to-end: real loopback socket + real child process ---------------- }

const
  E2E_PORT = 47831;

{$IF DEFINED(MSWINDOWS) AND NOT DEFINED(FPC)}
procedure Test_E2E_Http_ClientAgainstUdawServer;
var
  server: TUDAWMcpServer;
  transport: TMCPHttpTransport;
  client: IMCPClient;
  tools: TArray<string>;
  i: Integer;
  saw: Boolean;
  txt: string;
begin
  GServerTestDoc := TProjectDocument.CreateNew;
  GServerTestCmds := TCommandManager.Create;
  server := TUDAWMcpServer.Create;
  try
    server.Port := E2E_PORT;
    server.OnGetDoc := GMcpTestHost.GetDoc;
    server.OnGetCommands := GMcpTestHost.GetCommands;
    server.Start;
    Check(server.IsRunning, 'server is listening');

    transport := TMCPHttpTransport.Create;
    transport.Endpoint := 'http://127.0.0.1:' + IntToStr(E2E_PORT) + '/mcp';
    transport.Start;
    client := TMCPClient.Create;
    Check(client.Initialize(transport), 'client handshake with the live server succeeds: ' + client.LastError);
    Check(client.IsInitialized, 'client reports initialized');

    tools := client.ListTools;
    saw := False;
    for i := 0 to High(tools) do
      if tools[i] = 'GetProjectInfo' then saw := True;
    Check(saw, 'ListTools over HTTP returns the DAW tools');

    txt := client.CallTool('GetProjectInfo', '{}');
    Check(Pos('tempo_bpm', txt) > 0, 'CallTool over HTTP returns project info');

    txt := client.CallTool('AddTrack', '{"track":"X"}');
    CheckEqualInt(0, GServerTestDoc.Timeline.TrackCount, 'unconfirmed destructive call over HTTP changes nothing');
  finally
    client := nil;
    server.Free;
    GServerTestCmds.Free;
    GServerTestDoc.Free;
  end;
end;

procedure Test_E2E_Http_BearerTokenEnforced;
var
  server: TUDAWMcpServer;
  transport: TMCPHttpTransport;
  client: IMCPClient;
  ok, raised: Boolean;
begin
  server := TUDAWMcpServer.Create;
  try
    server.Port := E2E_PORT + 1;
    server.AuthToken := 'tok-123';
    server.Start;

    transport := TMCPHttpTransport.Create;
    transport.Endpoint := 'http://127.0.0.1:' + IntToStr(E2E_PORT + 1) + '/mcp';
    transport.Start;
    client := TMCPClient.Create;
    raised := False; ok := False;
    try
      ok := client.Initialize(transport);
    except
      raised := True;
    end;
    Check(raised or not ok, 'no token => handshake refused');

    transport := TMCPHttpTransport.Create;
    transport.Endpoint := 'http://127.0.0.1:' + IntToStr(E2E_PORT + 1) + '/mcp';
    transport.BearerToken := 'tok-123';
    transport.Start;
    client := TMCPClient.Create;
    Check(client.Initialize(transport), 'correct token => handshake succeeds: ' + client.LastError);
  finally
    client := nil;
    server.Free;
  end;
end;

procedure Test_E2E_Stdio_ClientAgainstChildProcess;
const
  SCRIPT =
    '$ErrorActionPreference = "Stop"' + sLineBreak +
    'while (($l = [Console]::In.ReadLine()) -ne $null) {' + sLineBreak +
    '  if ($l.Trim() -eq "") { continue }' + sLineBreak +
    '  $r = $l | ConvertFrom-Json' + sLineBreak +
    '  if ($null -eq $r.id) { continue }' + sLineBreak +
    '  switch ($r.method) {' + sLineBreak +
    '    "initialize" { $res = @{protocolVersion="2025-06-18";capabilities=@{tools=@{}};serverInfo=@{name="mock";version="1"}} }' + sLineBreak +
    '    "tools/list" { $res = @{tools=@(@{name="echo";description="Echo text";inputSchema=@{type="object";properties=@{text=@{type="string"}}}})} }' + sLineBreak +
    '    "tools/call" { $res = @{content=@(@{type="text";text=("echo:" + $r.params.arguments.text)});isError=$false} }' + sLineBreak +
    '    default { $res = @{} }' + sLineBreak +
    '  }' + sLineBreak +
    '  $o = @{jsonrpc="2.0";id=$r.id;result=$res} | ConvertTo-Json -Depth 12 -Compress' + sLineBreak +
    '  [Console]::Out.WriteLine($o); [Console]::Out.Flush()' + sLineBreak +
    '}' + sLineBreak;
var
  path: string;
  sl: TStringList;
  transport: TMCPStdioTransport;
  client: IMCPClient;
  tools: TArray<string>;
begin
  path := IncludeTrailingPathDelimiter(GetCurrentDir) + 'mcp_mock_stdio_server.ps1';
  sl := TStringList.Create;
  try
    sl.Text := SCRIPT;
    sl.SaveToFile(path);
  finally
    sl.Free;
  end;
  try
    transport := TMCPStdioTransport.Create;
    transport.CommandLine := 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + path + '"';
    transport.TimeoutMs := 20000;
    transport.Start;
    client := TMCPClient.Create;
    Check(client.Initialize(transport), 'handshake with a stdio child process: ' + client.LastError);
    tools := client.ListTools;
    CheckEqualInt(1, Length(tools), 'one tool discovered');
    CheckEqualStr('echo', tools[0], 'tool name');
    Check(Pos('echo:hello', client.CallTool('echo', '{"text":"hello"}')) > 0, 'tools/call round-trips through stdio');
  finally
    client := nil;   // releases the transport, which stops the child
    DeleteFile(path);
  end;
end;
function FixturePath(const AName: string): string;
var
  cands: array[0..2] of string;
  i: Integer;
begin
  cands[0] := 'tests' + PathDelim + 'fixtures' + PathDelim + AName;
  cands[1] := '..' + PathDelim + 'tests' + PathDelim + 'fixtures' + PathDelim + AName;
  cands[2] := '..' + PathDelim + '..' + PathDelim + 'tests' + PathDelim + 'fixtures' + PathDelim + AName;
  for i := 0 to High(cands) do
    if FileExists(cands[i]) then Exit(ExpandFileName(cands[i]));
  Fail('missing fixture ' + AName);
end;

procedure Test_E2E_Tls_And_Local_BothAvailable;
const
  TOKEN = 'tls-test-token';
var
  server: TUDAWMcpServer;
  r: TMCPDiagResult;
  base: Integer;
begin
  base := E2E_PORT + 10;
  GServerTestDoc := TProjectDocument.CreateNew;
  GServerTestCmds := TCommandManager.Create;
  server := TUDAWMcpServer.Create;
  try
    server.Port := base;
    server.TlsPort := base + 1;
    server.TlsBindAddress := '127.0.0.1';
    server.TlsCertFile := FixturePath('mcp_test_cert.pem');
    server.TlsKeyFile := FixturePath('mcp_test_key.pem');
    server.AuthToken := TOKEN;
    server.OnGetDoc := GMcpTestHost.GetDoc;
    server.OnGetCommands := GMcpTestHost.GetCommands;
    server.Start;
    Check(server.IsRunning, 'plain (local) listener up');
    Check(server.IsTlsRunning, 'TLS listener up alongside it');

    r := MCPTestEndpoint('http://127.0.0.1:' + IntToStr(base) + '/mcp', TOKEN, False);
    Check(r.Ok, 'LOCAL plain-HTTP connectivity test passes' + sLineBreak + r.Report);
    Check(r.ToolCount > 0, 'local: tools discovered');

    r := MCPTestEndpoint('https://127.0.0.1:' + IntToStr(base + 1) + '/mcp', TOKEN, True);
    Check(r.Ok, 'TLS connectivity test passes (self-signed allowed)' + sLineBreak + r.Report);
    Check(r.IsTls, 'the TLS run really used https');
    Check(Pos('TLS', r.Report) > 0, 'report carries TLS details: ' + r.Report);
    Check(r.ToolCount > 0, 'tls: tools discovered');

    r := MCPTestEndpoint('https://127.0.0.1:' + IntToStr(base + 1) + '/mcp', TOKEN, False);
    CheckFalse(r.Reachable, 'an untrusted self-signed cert is REJECTED when verification is on');

    r := MCPTestEndpoint('https://127.0.0.1:' + IntToStr(base + 1) + '/mcp', 'wrong-token', True);
    CheckFalse(r.Ok, 'wrong token over TLS is refused');
    Check(Pos('401', r.Report) > 0, 'refusal is an HTTP 401: ' + r.Report);

    r := MCPTestEndpoint('http://127.0.0.1:1/mcp', TOKEN, False, 3000);
    CheckFalse(r.Reachable, 'a dead port is reported unreachable, not a crash');
  finally
    server.Free;
    GServerTestCmds.Free;
    GServerTestDoc.Free;
  end;
end;

procedure Test_Tls_RefusedWithoutAuthToken;
var
  server: TUDAWMcpServer;
  raised: Boolean;
begin
  server := TUDAWMcpServer.Create;
  try
    server.Port := E2E_PORT + 20;
    server.TlsPort := E2E_PORT + 21;
    server.TlsCertFile := FixturePath('mcp_test_cert.pem');
    server.TlsKeyFile := FixturePath('mcp_test_key.pem');
    raised := False;
    try
      server.Start;
    except
      raised := True;
    end;
    Check(raised, 'HTTPS listener refuses to start with no auth token');
    CheckFalse(server.IsRunning, 'nothing was left half-started');
  finally
    server.Free;
  end;
end;

procedure Test_Tls_BadCertFile_FailsCleanly;
var
  server: TUDAWMcpServer;
  raised: Boolean;
begin
  server := TUDAWMcpServer.Create;
  try
    server.Port := E2E_PORT + 30;
    server.TlsPort := E2E_PORT + 31;
    server.AuthToken := 'x';
    server.TlsCertFile := 'Z:\no-such-dir\cert.pem';
    server.TlsKeyFile := 'Z:\no-such-dir\key.pem';
    raised := False;
    try
      server.Start;
    except
      raised := True;
    end;
    Check(raised, 'missing certificate => clear error');
    CheckFalse(server.IsRunning, 'plain listener rolled back too');
  finally
    server.Free;
  end;
end;
{$IFEND}

procedure RegisterPhase26MCPTests;
begin
  RegisterTest(GRP, 'Registry: SaveToFile/LoadFromFile round-trip', Test_Registry_SaveLoad_RoundTrip);
  RegisterTest(GRP, 'Registry: adding a duplicate name is rejected', Test_Registry_AddDuplicateName_Rejected);
  RegisterTest(GRP, 'Registry: Update changes a config in place', Test_Registry_Update_ChangesInPlace);
  RegisterTest(GRP, 'MCPBridge: parses a fenced mcp-tool block', Test_MCPBridge_ParseMCPToolCalls_ExtractsFencedBlock);
  RegisterTest(GRP, 'MCPBridge: malformed/incomplete blocks are skipped', Test_MCPBridge_ParseMCPToolCalls_MalformedSkipped);
  RegisterTest(GRP, 'MCPBridge: unknown server fails cleanly', Test_MCPBridge_Execute_UnknownServer_FailsCleanly);
  RegisterTest(GRP, 'MCPServer: tools/list advertises the built-in DAW tools', Test_McpServer_ToolsList_IncludesKnownTools);
  RegisterTest(GRP, 'MCPServer: tools/list publishes real input schemas', Test_McpServer_ToolsList_HasRealSchemas);
  RegisterTest(GRP, 'MusicTab: PDF is well-formed, escaped and paginated', Test_MusicTab_BuildsValidPdf);
  RegisterTest(GRP, 'MusicTab: file stem + fence stripping', Test_MusicTab_FileStemAndFences);
  RegisterTest(GRP, 'MCPServer: bearer-token authorization', Test_McpServer_Auth_BearerToken);
  RegisterTest(GRP, 'MCPServer: a read-only tool call works with no confirmation', Test_McpServer_ToolsCall_ReadOnly_WorksWithoutDestructiveFlag);
  RegisterTest(GRP, 'MCPServer: a destructive tool call is refused when AllowDestructive is off', Test_McpServer_ToolsCall_Destructive_RefusedWithoutAllowFlag);
  RegisterTest(GRP, 'MCPServer: a destructive tool call needs confirm=true even when allowed', Test_McpServer_ToolsCall_Destructive_RequiresConfirmEvenWhenAllowed);
  RegisterTest(GRP, 'MCPServer: an unknown JSON-RPC method returns a clean error', Test_McpServer_UnknownMethod_ReturnsJsonRpcError);
  RegisterTest(GRP, 'MCPServer: notifications get no response body', Test_McpServer_Notification_GetsNoResponseBody);
  RegisterTest(GRP, 'MCPServer: ping answered, string ids echoed', Test_McpServer_Ping_And_StringId_Echoed);
  RegisterTest(GRP, 'MCPServer: initialize negotiates the protocol version', Test_McpServer_Initialize_NegotiatesProtocolVersion);
  RegisterTest(GRP, 'MCPServer: Origin guard (DNS-rebinding)', Test_McpServer_OriginGuard);
  RegisterTest(GRP, 'MCPClient: HTTP reply unwraps SSE payloads', Test_McpHttp_ExtractJsonPayload_HandlesSse);
  {$IF DEFINED(MSWINDOWS) AND NOT DEFINED(FPC)}
  RegisterTest(GRP, 'E2E: MCP client <-> UDAW server over real loopback HTTP', Test_E2E_Http_ClientAgainstUdawServer);
  RegisterTest(GRP, 'E2E: HTTP bearer token enforced end to end', Test_E2E_Http_BearerTokenEnforced);
  RegisterTest(GRP, 'E2E: MCP client <-> stdio child process', Test_E2E_Stdio_ClientAgainstChildProcess);
  RegisterTest(GRP, 'E2E: local AND TLS listeners both available + connectivity diagnostics', Test_E2E_Tls_And_Local_BothAvailable);
  RegisterTest(GRP, 'TLS: refuses to start without an auth token', Test_Tls_RefusedWithoutAuthToken);
  RegisterTest(GRP, 'TLS: a missing certificate fails cleanly and rolls back', Test_Tls_BadCertFile_FailsCleanly);
  {$IFEND}
end;

initialization
  GMcpTestHost := TMcpServerTestHost.Create;

finalization
  GMcpTestHost.Free;

end.
