unit Tests.Phase24;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 24 acceptance tests - the Suno generation client.

  TSunoClient.SubmitGeneration / PollClips / WaitForCompletion / DownloadAudio
  need a real (self-hosted) proxy endpoint to exercise meaningfully - same
  rationale as every other Phase 20+ network-facing test in this suite - so
  those are left to interactive/manual testing. What IS verified here
  without any network access: clip-status text mapping and base-URL
  normalisation (trailing-slash trimming, the documented default).

  Requires src/common and src/ai on the search path. }

interface

procedure RegisterPhase24Tests;

implementation

uses
  SysUtils,
  UDAW.Errors, UDAW.AI.JSON,
  UDAW.Testing,
  UDAW.AI.Suno;

const
  GRP = 'phase24.suno';

procedure Test_ClipStatus_FromText;
begin
  Check(SunoClipStatusFromText('submitted') = scsSubmitted, 'submitted');
  Check(SunoClipStatusFromText('queued') = scsQueued, 'queued');
  Check(SunoClipStatusFromText('streaming') = scsStreaming, 'streaming');
  Check(SunoClipStatusFromText('complete') = scsComplete, 'complete');
  Check(SunoClipStatusFromText('completed') = scsComplete, 'completed alias');
  Check(SunoClipStatusFromText('COMPLETE') = scsComplete, 'case-insensitive');
  Check(SunoClipStatusFromText('error') = scsError, 'error');
  Check(SunoClipStatusFromText('  queued  ') = scsQueued, 'trims whitespace');
  Check(SunoClipStatusFromText('something-else') = scsUnknown, 'unrecognised -> unknown');
end;

procedure Test_Client_DefaultBaseURL;
var
  c: TSunoClient;
begin
  c := TSunoClient.Create('fake-key', '');
  try
    CheckEqualStr(SUNO_DEFAULT_BASE_URL, c.BaseURL, 'empty base URL falls back to the documented default');
  finally
    c.Free;
  end;
end;

procedure Test_Client_TrimsTrailingSlashes;
var
  c: TSunoClient;
begin
  c := TSunoClient.Create('fake-key', 'http://localhost:3000///');
  try
    CheckEqualStr('http://localhost:3000', c.BaseURL, 'trailing slashes trimmed');
  finally
    c.Free;
  end;
end;

procedure Test_ProxyStreamingAndValidation;
var c: TSunoClient; clips: TSunoClipArray; raised: Boolean;
begin
  c := TSunoClient.Create('', 'http://localhost:3000');
  try
    clips := c.ParseClipArray('[{"id":"one","status":"streaming","audio_url":"https://cdn.invalid/one.mp3"}]');
    Check(clips[0].Status = scsStreaming, 'preview URL must not signal completion');
    clips := c.ParseClipArray('{"clips":[{"id":"one","status":"complete","audio_url":"https://cdn.invalid/one.mp3"}]}');
    Check(clips[0].Status = scsComplete, 'explicit completion');
    raised := False;
    try c.ParseClipArray('{"data":{"taskId":"wrong-protocol"}}');
    except on EUDAWError do raised := True; end;
    Check(raised, 'wrong protocol must fail instead of polling an empty ID');
    CheckEqualStr('/api/get?ids=a%26b%3F,c', c.PollPath(['a&b?', 'c']), 'query IDs encoded separately');
    raised := False;
    try c.PollPath(['']); except on EUDAWError do raised := True; end;
    Check(raised, 'empty polling ID rejected');
  finally c.Free; end;
end;

procedure Test_ManagedTaskLifecycle;
var c: TSunoClient; clips: TSunoClipArray; raised: Boolean;
begin
  c := TSunoClient.Create('test', '', sakManaged);
  try
    CheckEqualStr('https://apibox.erweima.ai', c.BaseURL, 'managed default');
    clips := c.ParseClipArray('{"code":200,"data":{"taskId":"task-1"}}');
    Check(clips[0].Status = scsSubmitted, 'task submission');
    CheckEqualStr('task-1', clips[0].Id, 'retain task ID for polling');
    clips := c.ParseClipArray('{"code":200,"data":{"taskId":"task-1","status":"FIRST_SUCCESS","response":{"sunoData":[{"id":"one","audioUrl":"https://cdn.invalid/one.mp3"}]}}}');
    Check(clips[0].Status = scsStreaming, 'first take is not whole task completion');
    CheckEqualStr('task-1', clips[0].Id, 'pending task ID stays separate from clip ID');
    clips := c.ParseClipArray('{"code":200,"data":{"taskId":"task-1","status":"SUCCESS","response":{"sunoData":[{"id":"one","audioUrl":"https://cdn.invalid/one.mp3"},{"id":"two","audio_url":"https://cdn.invalid/two.mp3"}]}}}');
    Check(Length(clips) = 2, 'both takes retained');
    Check(clips[0].Status = scsComplete, 'task success completes clip');
    CheckEqualStr('https://cdn.invalid/one.mp3', clips[0].AudioURL, 'camel-case audio URL');
    clips := c.ParseClipArray('{"code":200,"data":{"taskId":"task-1","status":"GENERATE_AUDIO_FAILED"}}');
    Check(clips[0].Status = scsError, 'failure is terminal');
    raised := False;
    try c.ParseClipArray('{"code":429,"msg":"Insufficient credits","data":null}');
    except on EUDAWError do raised := True; end;
    Check(raised, 'API errors inside HTTP 200 envelopes rejected');
    raised := False;
    try c.ParseClipArray('{"code":200,"data":{"taskId":"task-1","status":"SUCCESS","response":{"sunoData":[]}}}');
    except on EUDAWError do raised := True; end;
    Check(raised, 'empty success is not imported');
    CheckEqualStr('/api/v1/generate/record-info?taskId=task-1', c.PollPath(['task-1']), 'managed poll endpoint');
  finally c.Free; end;
end;

procedure Test_ProviderPayloads;
var c: TSunoClient; req: TSunoGenerationRequest; v: TJSONValue; raised: Boolean;
begin
  req := Default(TSunoGenerationRequest);
  req.Prompt := 'Piano at 120 bpm'; req.Instrumental := True;
  c := TSunoClient.Create('');
  try
    CheckEqualStr('/api/generate', c.GenerationPath(req), 'description endpoint');
    v := Parse(c.GenerationBody(req));
    try
      Check(v.ByName('make_instrumental').AsBool, 'proxy instrumental field');
      Check(not v.HasName('customMode'), 'managed fields not sent to proxy');
    finally v.Free; end;
    req.CustomMode := True; req.Tags := 'piano'; req.Title := 'Study';
    CheckEqualStr('/api/custom_generate', c.GenerationPath(req), 'lyrics use custom endpoint');
  finally c.Free; end;
  c := TSunoClient.Create('key', '', sakManaged);
  try
    raised := False;
    try c.GenerationBody(req); except on EUDAWError do raised := True; end;
    Check(raised, 'require real callback and model before paid request');
    req.Model := 'V6'; req.CallbackURL := 'https://example.invalid/callback';
    v := Parse(c.GenerationBody(req));
    try
      Check(v.ByName('customMode').AsBool, 'managed custom flag');
      CheckEqualStr('piano', v.ByName('style').AsString, 'managed style field');
      Check(not v.HasName('make_instrumental'), 'proxy fields not sent to managed');
    finally v.Free; end;
  finally c.Free; end;
end;

procedure RegisterPhase24Tests;
begin
  RegisterTest(GRP, 'Suno: streaming and invalid proxy responses', Test_ProxyStreamingAndValidation);
  RegisterTest(GRP, 'Suno: managed task lifecycle', Test_ManagedTaskLifecycle);
  RegisterTest(GRP, 'Suno: provider payload contracts', Test_ProviderPayloads);
  RegisterTest(GRP, 'Suno: clip status text mapping', Test_ClipStatus_FromText);
  RegisterTest(GRP, 'Suno: default base URL', Test_Client_DefaultBaseURL);
  RegisterTest(GRP, 'Suno: base URL trailing-slash trim', Test_Client_TrimsTrailingSlashes);
end;

end.
