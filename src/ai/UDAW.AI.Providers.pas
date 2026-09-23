unit UDAW.AI.Providers;
{$I udaw.inc}

{ Phases 21-23 - a tiny factory that turns a AI_KNOWN_PROVIDERS id (see
  UDAW.AI.Credentials) plus a stored API key into a concrete IAIProvider.
  Suno (Phase 24) is a generation API, not a chat provider, so it is not a
  concrete IAIProvider and is intentionally not dispatched here - see
  UDAW.AI.Suno.TSunoClient instead. CreateAIProvider returns nil for any
  unrecognised chat-provider id, so callers (the AI tab) can fall back to
  "no live integration yet". }

interface

uses
  SysUtils, UDAW.AI.Types, UDAW.AI.OpenAI, UDAW.AI.Claude, UDAW.AI.DeepSeek;

function CreateAIProvider(const AProviderId, AApiKey: string): IAIProvider;

implementation

function CreateAIProvider(const AProviderId, AApiKey: string): IAIProvider;
var
  id: string;
begin
  id := LowerCase(AProviderId);
  if id = 'openai' then
    Result := TOpenAIProvider.Create(AApiKey)
  else if id = 'claude' then
    Result := TClaudeProvider.Create(AApiKey)
  else if id = 'deepseek' then
    Result := TDeepSeekProvider.Create(AApiKey)
  else
    Result := nil;
end;

end.
