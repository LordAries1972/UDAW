unit Tests.Phase21;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 21 acceptance tests - the OpenAI / ChatGPT provider.

  TOpenAIProvider.SendMessage / StreamMessage need a real network endpoint
  and a real API key to exercise meaningfully, so - matching how Phase 20
  left UDAW.AI.HTTP's actual Post/Get/PostStreaming untested - those are
  left to interactive/manual testing. What IS verified here without any
  network access: provider identity, and the UDAW.AI.Providers factory
  dispatch that the AI tab relies on to turn a stored provider id into a
  concrete IAIProvider.

  Requires src/common and src/ai on the search path. }

interface

procedure RegisterPhase21Tests;

implementation

uses
  SysUtils,
  UDAW.Testing,
  UDAW.AI.Types,
  UDAW.AI.OpenAI,
  UDAW.AI.Providers;

const
  GRP = 'phase21.openai';

procedure Test_OpenAI_Identity;
var
  p: IAIProvider;
begin
  p := TOpenAIProvider.Create('sk-fake-test-key');
  CheckEqualStr('openai', p.ProviderId, 'provider id');
  CheckEqualStr('OpenAI / ChatGPT', p.DisplayName, 'display name');
end;

procedure Test_Factory_DispatchesOpenAI;
var
  p: IAIProvider;
begin
  p := CreateAIProvider('openai', 'sk-fake-test-key');
  Check(p <> nil, 'factory returns a provider for "openai"');
  CheckEqualStr('openai', p.ProviderId, 'factory-created provider id');

  p := CreateAIProvider('OpenAI', 'sk-fake-test-key');
  Check(p <> nil, 'factory dispatch is case-insensitive');

  p := CreateAIProvider('suno', 'x');
  Check(p = nil, 'factory returns nil for suno (a generation client, not a chat IAIProvider)');

  p := CreateAIProvider('nonsense', 'x');
  Check(p = nil, 'factory returns nil for an unrecognised provider id');
end;

procedure RegisterPhase21Tests;
begin
  RegisterTest(GRP, 'OpenAI: provider identity', Test_OpenAI_Identity);
  RegisterTest(GRP, 'Providers: factory dispatch', Test_Factory_DispatchesOpenAI);
end;

end.
