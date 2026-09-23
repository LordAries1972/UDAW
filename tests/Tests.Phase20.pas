unit Tests.Phase20;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 20 acceptance tests - the AI foundation layer. Verified in memory
  with no network access and no child processes:

    * UDAW.AI.JSON: a nested document (object / string / number / bool /
      null / array-of-objects) parses correctly and every field reads back
      via ByName / Items; ToJSONString -> re-Parse is equivalent to the
      source; malformed JSON raises EUDAWError(errParse);
    * UDAW.AI.Credentials: the pure key-naming/lookup helpers only -
      IsKnownAIProvider, AICredentialKey, AIProviderDisplayName. Actual
      secret storage round-trips exercise the OS credential vault and are
      left to interactive/manual testing;
    * UDAW.AI.RateLimiter: token-bucket acquire/exhaust/Reset behaviour;
    * UDAW.AI.SecureLog: registered-secret redaction and defensive
      Bearer-token masking;
    * UDAW.AI.Types: TAIRole <-> id round-trip.

  UDAW.AI.HTTP and UDAW.AI.MCP are NOT exercised here beyond the
  no-network / no-process pieces (TAICancelToken, TMCPServerRegistry) -
  real HTTP calls and real child-process transports need a concrete
  provider/server to test against meaningfully, which arrives in Phase 21+.

  Requires src/common and src/ai on the search path. }

interface

procedure RegisterPhase20Tests;

implementation

uses
  SysUtils,
  UDAW.Testing,
  UDAW.Errors,
  UDAW.AI.JSON,
  UDAW.AI.Credentials,
  UDAW.AI.RateLimiter,
  UDAW.AI.SecureLog,
  UDAW.AI.Types,
  UDAW.AI.HTTP,
  UDAW.AI.MCP;

const
  GRP = 'phase20.aifoundation';

{ ---------------- JSON ---------------- }

procedure Test_JSON_ParseNested;
const
  DOC = '{"name":"clip","index":3,"active":true,"note":null,' +
        '"tags":[{"id":1,"v":"a"},{"id":2,"v":"b"}]}';
var
  v, tags, t0, t1: TJSONValue;
begin
  v := Parse(DOC);
  try
    CheckEqualInt(Ord(jkObject), Ord(v.Kind), 'top-level is an object');
    CheckEqualStr('clip', v.ByName('name').AsString, 'string field');
    CheckEqualInt(3, Trunc(v.ByName('index').AsNumber), 'number field');
    Check(v.ByName('active').AsBool, 'bool field');
    CheckEqualInt(Ord(jkNull), Ord(v.ByName('note').Kind), 'null field');

    tags := v.ByName('tags');
    Check(tags <> nil, 'tags present');
    CheckEqualInt(Ord(jkArray), Ord(tags.Kind), 'tags is an array');
    CheckEqualInt(2, tags.Count, 'two tag objects');

    t0 := tags.Items[0];
    t1 := tags.Items[1];
    CheckEqualInt(1, Trunc(t0.ByName('id').AsNumber), 'tag 0 id');
    CheckEqualStr('a', t0.ByName('v').AsString, 'tag 0 v');
    CheckEqualInt(2, Trunc(t1.ByName('id').AsNumber), 'tag 1 id');
    CheckEqualStr('b', t1.ByName('v').AsString, 'tag 1 v');

    CheckFalse(v.HasName('nonexistent'), 'HasName false for absent key');
    Check(v.ByName('nonexistent') = nil, 'ByName nil for absent key');
  finally
    v.Free;
  end;
end;

procedure Test_JSON_RoundTrip;
const
  DOC = '{"a":1,"b":[1,2,3],"c":"hello \"world\"","d":false}';
var
  v1, v2: TJSONValue;
  s1, s2: string;
begin
  v1 := Parse(DOC);
  try
    s1 := v1.ToJSONString;
  finally
    v1.Free;
  end;

  v2 := Parse(s1);
  try
    s2 := v2.ToJSONString;
  finally
    v2.Free;
  end;

  CheckEqualStr(s1, s2, 'ToJSONString -> Parse -> ToJSONString is stable');
end;

procedure Test_JSON_MalformedRaisesParseError;
var
  raised: Boolean;
  code: TUDAWErrorCode;
begin
  raised := False;
  code := errNone;
  try
    Parse('{"a": }').Free;
  except
    on E: EUDAWError do
    begin
      raised := True;
      code := E.Code;
    end;
  end;
  Check(raised, 'malformed JSON raises EUDAWError');
  CheckEqualInt(Ord(errParse), Ord(code), 'error code is errParse');
end;

{ ---------------- Credentials ---------------- }

procedure Test_Credentials_KeyNaming;
begin
  Check(IsKnownAIProvider('openai'), 'openai is known');
  Check(IsKnownAIProvider('claude'), 'claude is known');
  Check(IsKnownAIProvider('deepseek'), 'deepseek is known');
  Check(IsKnownAIProvider('suno'), 'suno is known');
  CheckFalse(IsKnownAIProvider('nonsense'), 'nonsense is not known');

  CheckEqualStr('openai.api_key', AICredentialKey('openai'), 'credential key naming');

  CheckEqualStr('OpenAI / ChatGPT', AIProviderDisplayName('openai'), 'openai display name');
  CheckEqualStr('Claude', AIProviderDisplayName('claude'), 'claude display name');
  CheckEqualStr('DeepSeek', AIProviderDisplayName('deepseek'), 'deepseek display name');
  CheckEqualStr('Suno', AIProviderDisplayName('suno'), 'suno display name');
  CheckEqualStr('Widget', AIProviderDisplayName('widget'), 'unknown provider capitalised');
end;

{ ---------------- RateLimiter ---------------- }

procedure Test_RateLimiter_AcquireAndExhaust;
var
  limiter: TAIRateLimiter;
  waitMs: Integer;
  i: Integer;
  ok: Boolean;
  everFailed: Boolean;
begin
  limiter := TAIRateLimiter.Create;
  try
    limiter.Configure(60, 6000);   // 60 req/min, 6000 tokens/min

    ok := limiter.TryAcquire(100, waitMs);
    Check(ok, 'first acquire succeeds');
    CheckEqualInt(0, waitMs, 'first acquire needs no wait');

    everFailed := False;
    for i := 1 to 200 do
    begin
      ok := limiter.TryAcquire(1000, waitMs);
      if not ok then
      begin
        everFailed := True;
        Check(waitMs > 0, 'a failed acquire suggests a positive wait');
        Break;
      end;
    end;
    Check(everFailed, 'hammering far beyond the configured budget eventually fails');

    limiter.Reset;
    ok := limiter.TryAcquire(100, waitMs);
    Check(ok, 'acquire succeeds again after Reset');
  finally
    limiter.Free;
  end;
end;

{ ---------------- SecureLog ---------------- }

procedure Test_SecureLog_Redaction;
var
  log: TAISecureLog;
  redacted: string;
begin
  log := TAISecureLog.Create;
  try
    log.RegisterSecret('sk-test-12345');
    redacted := log.Redact('the key is sk-test-12345 end');
    CheckFalse(Pos('sk-test-12345', redacted) > 0, 'registered secret is scrubbed');
    Check(Pos('****', redacted) > 0, 'redaction marker present');

    redacted := log.Redact('Authorization header: Bearer sometoken1234567890');
    CheckFalse(Pos('sometoken1234567890', redacted) > 0, 'bearer token masked without registration');
    Check(Pos('Bearer ****', redacted) > 0, 'bearer prefix kept, token masked');
  finally
    log.Free;
  end;
end;

{ ---------------- Types ---------------- }

procedure Test_AIRole_RoundTrip;
var
  r, back: TAIRole;
  id: string;
  ok: Boolean;
begin
  for r := Low(TAIRole) to High(TAIRole) do
  begin
    id := AIRoleId(r);
    Check(id <> '', 'role id is non-empty');
    ok := AIRoleFromId(id, back);
    Check(ok, Format('AIRoleFromId succeeds for "%s"', [id]));
    CheckEqualInt(Ord(r), Ord(back), Format('round-trip for role %s', [id]));
  end;
end;

{ ---------------- HTTP / MCP (no network, no process) ---------------- }

procedure Test_CancelToken;
var
  tok: TAICancelToken;
begin
  tok := TAICancelToken.Create;
  try
    CheckFalse(tok.IsCancelled, 'not cancelled initially');
    tok.Cancel;
    Check(tok.IsCancelled, 'cancelled after Cancel');
  finally
    tok.Free;
  end;
end;

procedure Test_MCPServerRegistry_InMemory;
var
  reg: TMCPServerRegistry;
  cfg: TMCPServerConfig;
  found: TMCPServerConfig;
begin
  reg := TMCPServerRegistry.Create;
  try
    CheckEqualInt(0, reg.Count, 'empty registry starts at zero');

    cfg.Name := 'local-fs';
    cfg.CommandLine := 'mcp-fs-server --root .';
    cfg.HttpEndpoint := '';
    cfg.UseStdio := True;
    reg.Add(cfg);

    cfg.Name := 'remote-tools';
    cfg.CommandLine := '';
    cfg.HttpEndpoint := 'https://example.invalid/mcp';
    cfg.UseStdio := False;
    reg.Add(cfg);

    CheckEqualInt(2, reg.Count, 'two servers registered');
    Check(reg.FindByName('local-fs', found), 'find by name succeeds');
    Check(found.UseStdio, 'found config keeps UseStdio');
    CheckEqualStr('mcp-fs-server --root .', found.CommandLine, 'found config keeps CommandLine');

    reg.Remove('local-fs');
    CheckEqualInt(1, reg.Count, 'one server left after remove');
    CheckFalse(reg.FindByName('local-fs', found), 'removed server no longer found');
    Check(reg.FindByName('remote-tools', found), 'remaining server still found');
  finally
    reg.Free;
  end;
end;

procedure RegisterPhase20Tests;
begin
  RegisterTest(GRP, 'JSON: parse nested document + field access', Test_JSON_ParseNested);
  RegisterTest(GRP, 'JSON: ToJSONString -> Parse round-trip', Test_JSON_RoundTrip);
  RegisterTest(GRP, 'JSON: malformed input raises errParse', Test_JSON_MalformedRaisesParseError);
  RegisterTest(GRP, 'Credentials: key naming + display names', Test_Credentials_KeyNaming);
  RegisterTest(GRP, 'RateLimiter: acquire, exhaust, reset', Test_RateLimiter_AcquireAndExhaust);
  RegisterTest(GRP, 'SecureLog: registered-secret + bearer-token redaction', Test_SecureLog_Redaction);
  RegisterTest(GRP, 'Types: TAIRole <-> id round-trip', Test_AIRole_RoundTrip);
  RegisterTest(GRP, 'HTTP: cancel token', Test_CancelToken);
  RegisterTest(GRP, 'MCP: in-memory server registry add/find/remove', Test_MCPServerRegistry_InMemory);
end;

end.
