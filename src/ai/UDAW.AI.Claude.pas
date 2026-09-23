unit UDAW.AI.Claude;
{$I udaw.inc}

{ Phase 22 - Claude provider. Concrete IAIProvider built on the Phase 20
  foundation (UDAW.AI.HTTP for transport, UDAW.AI.JSON for the request/
  response bodies). Talks to the Anthropic Messages REST endpoint directly;
  no Anthropic SDK is used, matching this project's from-scratch policy for
  every external format/protocol it speaks.

  The Messages API has no "system" role inside the messages array (unlike
  OpenAI) - any arSystem messages in the request are concatenated into the
  top-level "system" field instead. arTool messages have no first-class
  mapping yet (that arrives with the structured tool bridge in Phase 26) and
  are folded into a "user" turn tagged "[tool]:" so a conversation still
  round-trips rather than silently dropping content. }

interface

uses
  SysUtils, Classes, StrUtils, UDAW.Errors, UDAW.AI.Types, UDAW.AI.HTTP, UDAW.AI.JSON;

const
  CLAUDE_DEFAULT_MODEL = 'claude-sonnet-5';
  CLAUDE_API_VERSION = '2023-06-01';
  CLAUDE_MESSAGES_URL = 'https://api.anthropic.com/v1/messages';
  CLAUDE_MODELS_URL = 'https://api.anthropic.com/v1/models';
  CLAUDE_DEFAULT_MAX_TOKENS = 1024;

type
  TClaudeProvider = class(TInterfacedObject, IAIProvider)
  private
    FApiKey: string;
    FModel: string;
    FHttp: TAIHttpClient;
    FStreamAccum: string;
    FStreamDelta: TAIStreamDeltaProc;
    function BuildRequestBody(const ARequest: TAIRequest; AStream: Boolean): string;
    function ParseResponse(const ABody: string): TAIResponse;
    procedure OnStreamLine(const ALine: string);
  public
    constructor Create(const AApiKey: string; const AModel: string = CLAUDE_DEFAULT_MODEL);
    destructor Destroy; override;

    function ProviderId: string;
    function DisplayName: string;
    function SendMessage(const ARequest: TAIRequest; ACancel: TObject): TAIResponse;
    function StreamMessage(const ARequest: TAIRequest; ADelta: TAIStreamDeltaProc;
      ACancel: TObject): TAIResponse;
    function ListModels: TArray<string>;
  end;

implementation

const
  SUBSYS = 'AI.Claude';

constructor TClaudeProvider.Create(const AApiKey: string; const AModel: string);
begin
  inherited Create;
  FApiKey := AApiKey;
  FModel := AModel;
  if FModel = '' then FModel := CLAUDE_DEFAULT_MODEL;
  FHttp := TAIHttpClient.Create;
  { The AI-tab timeline-generation flow can ask for up to 16384 output
    tokens (see TfrmMain.SendAiChatPrompt's ABatchConfirm branch); a reply
    that long routinely takes well over 60s to stream back, which was
    tripping WinInet error 12002 ("operation timed out") mid-generation. }
  FHttp.Configure(180000);
end;

destructor TClaudeProvider.Destroy;
begin
  FHttp.Free;
  inherited Destroy;
end;

function TClaudeProvider.ProviderId: string;
begin
  Result := 'claude';
end;

function TClaudeProvider.DisplayName: string;
begin
  Result := 'Claude';
end;

function TClaudeProvider.BuildRequestBody(const ARequest: TAIRequest; AStream: Boolean): string;
var
  root, msgs, one: TJSONValue;
  i, maxTokens: Integer;
  systemText, role, content, model: string;
begin
  systemText := '';
  model := ARequest.Model;
  if model = '' then model := FModel;
  root := JSONObject;
  try
    root.AddPair('model', JSONString(model));
    maxTokens := ARequest.MaxTokens;
    if maxTokens <= 0 then maxTokens := CLAUDE_DEFAULT_MAX_TOKENS;
    root.AddPair('max_tokens', JSONNumber(maxTokens));
    { Newer Claude models (e.g. claude-sonnet-5) reject an explicit
      "temperature" field outright ("temperature is deprecated for this
      model") rather than merely ignoring it, so it is omitted here and the
      API's own default is used. }

    msgs := JSONArray;
    for i := 0 to High(ARequest.Messages) do
    begin
      content := ARequest.Messages[i].Content;
      case ARequest.Messages[i].Role of
        arSystem:
        begin
          if systemText <> '' then systemText := systemText + sLineBreak;
          systemText := systemText + content;
          Continue;
        end;
        arAssistant: role := 'assistant';
        arTool:
        begin
          role := 'user';
          content := '[tool]: ' + content;
        end;
      else
        role := 'user';
      end;
      one := JSONObject;
      one.AddPair('role', JSONString(role));
      one.AddPair('content', JSONString(content));
      msgs.AddItem(one);
    end;
    root.AddPair('messages', msgs);
    if systemText <> '' then
      root.AddPair('system', JSONString(systemText));
    root.AddPair('stream', JSONBool(AStream));
    Result := root.ToJSONString;
  finally
    root.Free;
  end;
end;

function TClaudeProvider.ParseResponse(const ABody: string): TAIResponse;
var
  v, err, content, block, usage: TJSONValue;
  i: Integer;
  text: string;
begin
  Result.Content := '';
  Result.FinishReason := '';
  Result.PromptTokens := 0;
  Result.CompletionTokens := 0;
  v := Parse(ABody);
  try
    if v.HasName('error') then
    begin
      err := v.ByName('error');
      if err.HasName('message') then
        RaiseUDAWFmt(errNetwork, SUBSYS, 'Claude error: %s', [err.ByName('message').AsString])
      else
        RaiseUDAWFmt(errNetwork, SUBSYS, 'Claude error: %s', [ABody]);
    end;
    content := v.ByName('content');
    text := '';
    if content <> nil then
      for i := 0 to content.Count - 1 do
      begin
        block := content.Items[i];
        if block.HasName('type') and (block.ByName('type').AsString = 'text') and block.HasName('text') then
          text := text + block.ByName('text').AsString;
      end;
    Result.Content := text;
    if v.HasName('stop_reason') then
      Result.FinishReason := v.ByName('stop_reason').AsString;
    if v.HasName('usage') then
    begin
      usage := v.ByName('usage');
      if usage.HasName('input_tokens') then
        Result.PromptTokens := Round(usage.ByName('input_tokens').AsNumber);
      if usage.HasName('output_tokens') then
        Result.CompletionTokens := Round(usage.ByName('output_tokens').AsNumber);
    end;
  finally
    v.Free;
  end;
end;

function TClaudeProvider.SendMessage(const ARequest: TAIRequest; ACancel: TObject): TAIResponse;
var
  headers: array[0..2] of TAIHttpHeader;
  resp: TAIHttpResponse;
  body: string;
begin
  headers[0].Name := 'x-api-key'; headers[0].Value := FApiKey;
  headers[1].Name := 'anthropic-version'; headers[1].Value := CLAUDE_API_VERSION;
  headers[2].Name := 'content-type'; headers[2].Value := 'application/json';
  body := BuildRequestBody(ARequest, False);
  resp := FHttp.Post(CLAUDE_MESSAGES_URL, headers, body, TAICancelToken(ACancel));
  if resp.StatusCode <> 200 then
    RaiseUDAWFmt(errNetwork, SUBSYS, 'Claude HTTP %d: %s', [resp.StatusCode, resp.Body]);
  Result := ParseResponse(resp.Body);
end;

procedure TClaudeProvider.OnStreamLine(const ALine: string);
var
  line, data, txt: string;
  v, delta: TJSONValue;
begin
  line := Trim(ALine);
  if line = '' then Exit;
  if not StartsText('data:', line) then Exit; // skip "event: ..." framing lines
  data := Trim(Copy(line, Length('data:') + 1, MaxInt));
  if data = '' then Exit;
  try
    v := Parse(data);
  except
    Exit; // partial/malformed SSE chunk - ignore, matching PostStreaming's line-replay fallback
  end;
  try
    if not v.HasName('delta') then Exit;
    delta := v.ByName('delta');
    if delta.HasName('text') then
    begin
      txt := delta.ByName('text').AsString;
      FStreamAccum := FStreamAccum + txt;
      if Assigned(FStreamDelta) then
        FStreamDelta(txt);
    end;
  finally
    v.Free;
  end;
end;

function TClaudeProvider.StreamMessage(const ARequest: TAIRequest; ADelta: TAIStreamDeltaProc;
  ACancel: TObject): TAIResponse;
var
  headers: array[0..2] of TAIHttpHeader;
  resp: TAIHttpResponse;
  body: string;
begin
  FStreamAccum := '';
  FStreamDelta := ADelta;
  headers[0].Name := 'x-api-key'; headers[0].Value := FApiKey;
  headers[1].Name := 'anthropic-version'; headers[1].Value := CLAUDE_API_VERSION;
  headers[2].Name := 'content-type'; headers[2].Value := 'application/json';
  body := BuildRequestBody(ARequest, True);
  resp := FHttp.PostStreaming(CLAUDE_MESSAGES_URL, headers, body, OnStreamLine, TAICancelToken(ACancel));
  if resp.StatusCode <> 200 then
    RaiseUDAWFmt(errNetwork, SUBSYS, 'Claude HTTP %d: %s', [resp.StatusCode, resp.Body]);
  Result.Content := FStreamAccum;
  Result.FinishReason := 'end_turn';
  Result.PromptTokens := 0;
  Result.CompletionTokens := 0;
end;

function TClaudeProvider.ListModels: TArray<string>;
var
  headers: array[0..1] of TAIHttpHeader;
  resp: TAIHttpResponse;
  v, data, item: TJSONValue;
  i: Integer;
  id: string;
  list: TStringList;
begin
  Result := nil;
  headers[0].Name := 'x-api-key'; headers[0].Value := FApiKey;
  headers[1].Name := 'anthropic-version'; headers[1].Value := CLAUDE_API_VERSION;
  try
    resp := FHttp.Get(CLAUDE_MODELS_URL, headers);
  except
    Exit;
  end;
  if resp.StatusCode <> 200 then Exit;
  try
    v := Parse(resp.Body);
  except
    Exit;
  end;
  list := TStringList.Create;
  try
    list.Sorted := True;
    list.Duplicates := dupIgnore;
    try
      data := v.ByName('data');
      if data <> nil then
        for i := 0 to data.Count - 1 do
        begin
          item := data.Items[i];
          if (item = nil) or not item.HasName('id') then Continue;
          id := item.ByName('id').AsString;
          if id <> '' then
            list.Add(id);
        end;
    finally
      v.Free;
    end;
    SetLength(Result, list.Count);
    for i := 0 to list.Count - 1 do
      Result[i] := list[i];
  finally
    list.Free;
  end;
end;

end.
