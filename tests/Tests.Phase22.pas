unit Tests.Phase22;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 22 acceptance tests - the Claude provider.

  TClaudeProvider.SendMessage / StreamMessage need a real network endpoint
  and a real API key to exercise meaningfully (same rationale as Phase 21's
  OpenAI tests and Phase 20's UDAW.AI.HTTP tests), so those are left to
  interactive/manual testing. What IS verified here without any network
  access: provider identity and the UDAW.AI.Providers factory dispatch.

  Requires src/common and src/ai on the search path. }

interface

procedure RegisterPhase22Tests;

implementation

uses
  SysUtils,
  UDAW.Testing,
  UDAW.AI.Types,
  UDAW.AI.Claude,
  UDAW.AI.Providers;

const
  GRP = 'phase22.claude';

procedure Test_Claude_Identity;
var
  p: IAIProvider;
begin
  p := TClaudeProvider.Create('fake-test-key');
  CheckEqualStr('claude', p.ProviderId, 'provider id');
  CheckEqualStr('Claude', p.DisplayName, 'display name');
end;

procedure Test_Factory_DispatchesClaude;
var
  p: IAIProvider;
begin
  p := CreateAIProvider('claude', 'fake-test-key');
  Check(p <> nil, 'factory returns a provider for "claude"');
  CheckEqualStr('claude', p.ProviderId, 'factory-created provider id');

  p := CreateAIProvider('Claude', 'fake-test-key');
  Check(p <> nil, 'factory dispatch is case-insensitive');
end;

procedure RegisterPhase22Tests;
begin
  RegisterTest(GRP, 'Claude: provider identity', Test_Claude_Identity);
  RegisterTest(GRP, 'Providers: factory dispatch', Test_Factory_DispatchesClaude);
end;

end.
