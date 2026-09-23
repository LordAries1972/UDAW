unit Tests.Phase23;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 23 acceptance tests - the DeepSeek provider.

  TDeepSeekProvider.SendMessage / StreamMessage need a real network endpoint
  and a real API key to exercise meaningfully (same rationale as Phase 21's
  OpenAI tests, Phase 22's Claude tests, and Phase 20's UDAW.AI.HTTP tests),
  so those are left to interactive/manual testing. What IS verified here
  without any network access: provider identity and the UDAW.AI.Providers
  factory dispatch.

  Requires src/common and src/ai on the search path. }

interface

procedure RegisterPhase23Tests;

implementation

uses
  SysUtils,
  UDAW.Testing,
  UDAW.AI.Types,
  UDAW.AI.DeepSeek,
  UDAW.AI.Providers;

const
  GRP = 'phase23.deepseek';

procedure Test_DeepSeek_Identity;
var
  p: IAIProvider;
begin
  p := TDeepSeekProvider.Create('fake-test-key');
  CheckEqualStr('deepseek', p.ProviderId, 'provider id');
  CheckEqualStr('DeepSeek', p.DisplayName, 'display name');
end;

procedure Test_Factory_DispatchesDeepSeek;
var
  p: IAIProvider;
begin
  p := CreateAIProvider('deepseek', 'fake-test-key');
  Check(p <> nil, 'factory returns a provider for "deepseek"');
  CheckEqualStr('deepseek', p.ProviderId, 'factory-created provider id');

  p := CreateAIProvider('DeepSeek', 'fake-test-key');
  Check(p <> nil, 'factory dispatch is case-insensitive');
end;

procedure RegisterPhase23Tests;
begin
  RegisterTest(GRP, 'DeepSeek: provider identity', Test_DeepSeek_Identity);
  RegisterTest(GRP, 'Providers: factory dispatch', Test_Factory_DispatchesDeepSeek);
end;

end.
