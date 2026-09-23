unit UDAW.AI.Types;
{$I udaw.inc}

{ Phase 20 - shared chat-style request/response vocabulary for AI providers.
  This unit defines the ABSTRACTION ONLY: no concrete provider is implemented
  in Phase 20. Phases 21 (OpenAI), 22 (Claude) and 23 (DeepSeek) supply
  concrete IAIProvider implementations built on UDAW.AI.HTTP + UDAW.AI.JSON. }

interface

uses
  SysUtils;

type
  TAIRole = (arSystem, arUser, arAssistant, arTool);

  TAIMessage = record
    Role: TAIRole;
    Content: string;
  end;

  TAIRequest = record
    Model: string;
    Messages: TArray<TAIMessage>;
    Temperature: Double;
    MaxTokens: Integer;
    Stream: Boolean;
  end;

  TAIResponse = record
    Content: string;
    FinishReason: string;
    PromptTokens: Integer;
    CompletionTokens: Integer;
  end;

  TAIStreamDeltaProc = procedure(const ADeltaText: string) of object;

  { ACancel is typed TObject here (expected to be a UDAW.AI.HTTP.TAICancelToken,
    cast by the concrete provider unit) to avoid a hard dependency from this
    low-level shared-types unit onto UDAW.AI.HTTP. }
  IAIProvider = interface
    ['{B3E1D9F4-6A2C-4C1E-9E0D-7F5A8B2C4D31}']
    function ProviderId: string;
    function DisplayName: string;
    function SendMessage(const ARequest: TAIRequest; ACancel: TObject): TAIResponse;
    function StreamMessage(const ARequest: TAIRequest; ADelta: TAIStreamDeltaProc;
      ACancel: TObject): TAIResponse;
    { Fetches the provider's list of available model ids from its REST API.
      Returns an empty array on any network/parse failure rather than
      raising, so a caller can treat "no models" as a soft failure. }
    function ListModels: TArray<string>;
  end;

function AIRoleId(ARole: TAIRole): string;
function AIRoleFromId(const AId: string; out ARole: TAIRole): Boolean;

implementation

function AIRoleId(ARole: TAIRole): string;
begin
  case ARole of
    arSystem:    Result := 'system';
    arUser:      Result := 'user';
    arAssistant: Result := 'assistant';
    arTool:      Result := 'tool';
  else
    Result := 'user';
  end;
end;

function AIRoleFromId(const AId: string; out ARole: TAIRole): Boolean;
var
  r: TAIRole;
begin
  for r := Low(TAIRole) to High(TAIRole) do
    if SameText(AId, AIRoleId(r)) then
    begin
      ARole := r;
      Exit(True);
    end;
  Result := False;
end;

end.
