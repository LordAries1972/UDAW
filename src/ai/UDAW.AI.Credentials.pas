unit UDAW.AI.Credentials;
{$I udaw.inc}

{ Phase 20 - AI-specific convenience layer over UDAW.SecureStorage.

  This unit does NOT implement its own secret storage: every credential is
  kept by the OS-backed ISecureStore (DPAPI / Keychain / libsecret) exactly
  like any other UDAW secret. All this unit adds is a small, consistent
  key-naming convention ('<providerId>.api_key') and provider metadata
  (display names, the list of provider ids known to Phases 21-24) so the AI
  tab and the future provider units don't each invent their own key scheme. }

interface

uses
  SysUtils, UDAW.SecureStorage;

const
  AI_KNOWN_PROVIDERS: array[0..4] of string = ('openai', 'claude', 'deepseek', 'suno', 'luma');

function AIProviderDisplayName(const AProviderId: string): string;
function AICredentialKey(const AProviderId: string): string;
function IsKnownAIProvider(const AProviderId: string): Boolean;

procedure SetAIApiKey(const AProviderId, AApiKey: string);
function GetAIApiKey(const AProviderId: string; out AApiKey: string): Boolean;
function HasAIApiKey(const AProviderId: string): Boolean;
procedure DeleteAIApiKey(const AProviderId: string);

{ MCP credentials - same OS secure store, never the registry text file.
  Client: bearer token UDAW sends to a configured HTTP MCP server (keyed by
  the server's registry name). Server: the bearer token an external MCP client
  must present to UDAW's own exposed MCP server (generated on first use). }
function MCPClientTokenKey(const AServerName: string): string;
procedure SetMCPClientToken(const AServerName, AToken: string);
function GetMCPClientToken(const AServerName: string; out AToken: string): Boolean;
procedure DeleteMCPClientToken(const AServerName: string);
function EnsureMCPServerToken: string;
procedure RegenerateMCPServerToken;
function GenerateMCPToken: string;

implementation

function CapitalizeId(const AProviderId: string): string;
begin
  Result := AProviderId;
  if Length(Result) > 0 then
    Result[1] := UpCase(Result[1]);
end;

function AIProviderDisplayName(const AProviderId: string): string;
var
  id: string;
begin
  id := LowerCase(AProviderId);
  if id = 'openai' then
    Result := 'OpenAI / ChatGPT'
  else if id = 'claude' then
    Result := 'Claude'
  else if id = 'deepseek' then
    Result := 'DeepSeek'
  else if id = 'suno' then
    Result := 'Suno'
  else if id = 'luma' then
    Result := 'Luma (video/image)'
  else
    Result := CapitalizeId(AProviderId);
end;

function AICredentialKey(const AProviderId: string): string;
begin
  Result := AProviderId + '.api_key';
end;

function IsKnownAIProvider(const AProviderId: string): Boolean;
var
  i: Integer;
  id: string;
begin
  id := LowerCase(AProviderId);
  for i := Low(AI_KNOWN_PROVIDERS) to High(AI_KNOWN_PROVIDERS) do
    if AI_KNOWN_PROVIDERS[i] = id then
      Exit(True);
  Result := False;
end;

procedure SetAIApiKey(const AProviderId, AApiKey: string);
begin
  SecureStore.SetSecret(AICredentialKey(AProviderId), AApiKey);
end;

function GetAIApiKey(const AProviderId: string; out AApiKey: string): Boolean;
begin
  Result := SecureStore.GetSecret(AICredentialKey(AProviderId), AApiKey);
end;

function HasAIApiKey(const AProviderId: string): Boolean;
begin
  Result := SecureStore.HasSecret(AICredentialKey(AProviderId));
end;

procedure DeleteAIApiKey(const AProviderId: string);
begin
  SecureStore.DeleteSecret(AICredentialKey(AProviderId));
end;

const
  MCP_SERVER_TOKEN_KEY = 'mcp.server.token';

function MCPClientTokenKey(const AServerName: string): string;
begin
  Result := 'mcp.client.' + LowerCase(Trim(AServerName)) + '.token';
end;

procedure SetMCPClientToken(const AServerName, AToken: string);
begin
  SecureStore.SetSecret(MCPClientTokenKey(AServerName), AToken);
end;

function GetMCPClientToken(const AServerName: string; out AToken: string): Boolean;
begin
  Result := SecureStore.GetSecret(MCPClientTokenKey(AServerName), AToken) and (AToken <> '');
end;

procedure DeleteMCPClientToken(const AServerName: string);
begin
  SecureStore.DeleteSecret(MCPClientTokenKey(AServerName));
end;

function GenerateMCPToken: string;
begin
  { two random (v4) GUIDs = 244 random bits, hex only }
  Result := 'udaw_' + StringReplace(StringReplace(GUIDToString(TGUID.NewGuid) +
    GUIDToString(TGUID.NewGuid), '{', '', [rfReplaceAll]), '}', '', [rfReplaceAll]);
  Result := StringReplace(Result, '-', '', [rfReplaceAll]);
end;

function EnsureMCPServerToken: string;
begin
  if not (SecureStore.GetSecret(MCP_SERVER_TOKEN_KEY, Result) and (Result <> '')) then
  begin
    Result := GenerateMCPToken;
    SecureStore.SetSecret(MCP_SERVER_TOKEN_KEY, Result);
  end;
end;

procedure RegenerateMCPServerToken;
begin
  SecureStore.SetSecret(MCP_SERVER_TOKEN_KEY, GenerateMCPToken);
end;

end.
