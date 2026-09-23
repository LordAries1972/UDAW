unit UDAW.AI.OpenAI;
{$I udaw.inc}

{ Phase 21 - OpenAI / ChatGPT provider. Concrete IAIProvider built on the
  Phase 20 foundation (UDAW.AI.HTTP for transport, UDAW.AI.JSON for the
  request/response bodies). Talks to the Chat Completions REST endpoint;
  no OpenAI SDK is used, matching this project's from-scratch policy for
  every external format/protocol it speaks. }

interface

uses
  SysUtils, Classes, StrUtils, UDAW.Errors, UDAW.AI.Types, UDAW.AI.HTTP, UDAW.AI.JSON;

const
  OPENAI_DEFAULT_MODEL = 'gpt-4o-mini';
  OPENAI_CHAT_URL = 'https://api.openai.com/v1/chat/completions';
  OPENAI_MODELS_URL = 'https://api.openai.com/v1/models';

type
  TOpenAIProvider = class(TInterfacedObject, IAIProvider)
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
    constructor Create(const AApiKey: string; const AModel: string = OPENAI_DEFAULT_MODEL);
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
  SUBSYS = 'AI.OpenAI';

constructor TOpenAIProvider.Create(const AApiKey: string; const AModel: string);
begin
  inherited Create;
  FApiKey := AApiKey;
  FModel := AModel;
  if FModel = '' then FModel := OPENAI_DEFAULT_MODEL;
  FHttp := TAIHttpClient.Create;
  { See UDAW.AI.Claude.pas' TClaudeProvider.Create for why this is 180s and
    not 60s: the AI-tab batch-generation flow can request up to 16384 output
    tokens, which routinely takes longer than 60s to stream back. }
  FHttp.Configure(180000);
end;

destructor TOpenAIProvider.Destroy;
begin
  FHttp.Free;
  inherited Destroy;
end;

function TOpenAIProvider.ProviderId: string;
begin
  Result := 'openai';
end;

function TOpenAIProvider.DisplayName: string;
begin
  Result := 'OpenAI / ChatGPT';
end;

function TOpenAIProvider.BuildRequestBody(const ARequest: TAIRequest; AStream: Boolean): string;
var
  root, msgs, one: TJSONValue;
  i: Integer;
  model: string;
begin
  model := ARequest.Model;
  if model = '' then model := FModel;
  root := JSONObject;
  try
    root.AddPair('model', JSONString(model));
    msgs := JSONArray;
    for i := 0 to High(ARequest.Messages) do
    begin
      one := JSONObject;
      one.AddPair('role', JSONString(AIRoleId(ARequest.Messages[i].Role)));
      one.AddPair('content', JSONString(ARequest.Messages[i].Content));
      msgs.AddItem(one);
    end;
    root.AddPair('messages', msgs);
    root.AddPair('temperature', JSONNumber(ARequest.Temperature));
    if ARequest.MaxTokens > 0 then
      root.AddPair('max_tokens', JSONNumber(ARequest.MaxTokens));
    root.AddPair('stream', JSONBool(AStream));
    Result := root.ToJSONString;
  finally
    root.Free;
  end;
end;

function TOpenAIProvider.ParseResponse(const ABody: string): TAIResponse;
var
  v, err, choices, choice, msg, usage: TJSONValue;
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
        RaiseUDAWFmt(errNetwork, SUBSYS, 'OpenAI error: %s', [err.ByName('message').AsString])
      else
        RaiseUDAWFmt(errNetwork, SUBSYS, 'OpenAI error: %s', [ABody]);
    end;
    choices := v.ByName('choices');
    if (choices = nil) or (choices.Count = 0) then
      RaiseUDAWFmt(errNetwork, SUBSYS, 'OpenAI response had no choices: %s', [ABody]);
    choice := choices.Items[0];
    msg := choice.ByName('message');
    if msg <> nil then
      Result.Content := msg.ByName('content').AsString;
    if choice.HasName('finish_reason') then
      Result.FinishReason := choice.ByName('finish_reason').AsString;
    if v.HasName('usage') then
    begin
      usage := v.ByName('usage');
      if usage.HasName('prompt_tokens') then
        Result.PromptTokens := Round(usage.ByName('prompt_tokens').AsNumber);
      if usage.HasName('completion_tokens') then
        Result.CompletionTokens := Round(usage.ByName('completion_tokens').AsNumber);
    end;
  finally
    v.Free;
  end;
end;

function TOpenAIProvider.SendMessage(const ARequest: TAIRequest; ACancel: TObject): TAIResponse;
var
  headers: array[0..1] of TAIHttpHeader;
  resp: TAIHttpResponse;
  body: string;
begin
  headers[0].Name := 'Authorization'; headers[0].Value := 'Bearer ' + FApiKey;
  headers[1].Name := 'Content-Type'; headers[1].Value := 'application/json';
  body := BuildRequestBody(ARequest, False);
  resp := FHttp.Post(OPENAI_CHAT_URL, headers, body, TAICancelToken(ACancel));
  if resp.StatusCode <> 200 then
    RaiseUDAWFmt(errNetwork, SUBSYS, 'OpenAI HTTP %d: %s', [resp.StatusCode, resp.Body]);
  Result := ParseResponse(resp.Body);
end;

procedure TOpenAIProvider.OnStreamLine(const ALine: string);
var
  line, data, txt: string;
  v, choices, choice, delta: TJSONValue;
begin
  line := Trim(ALine);
  if line = '' then Exit;
  if not StartsText('data:', line) then Exit;
  data := Trim(Copy(line, Length('data:') + 1, MaxInt));
  if data = '[DONE]' then Exit;
  try
    v := Parse(data);
  except
    Exit; // a partial/malformed SSE chunk - ignore, matching PostStreaming's line-replay fallback
  end;
  try
    choices := v.ByName('choices');
    if (choices = nil) or (choices.Count = 0) then Exit;
    choice := choices.Items[0];
    delta := choice.ByName('delta');
    if (delta <> nil) and delta.HasName('content') then
    begin
      txt := delta.ByName('content').AsString;
      FStreamAccum := FStreamAccum + txt;
      if Assigned(FStreamDelta) then
        FStreamDelta(txt);
    end;
  finally
    v.Free;
  end;
end;

function TOpenAIProvider.StreamMessage(const ARequest: TAIRequest; ADelta: TAIStreamDeltaProc;
  ACancel: TObject): TAIResponse;
var
  headers: array[0..1] of TAIHttpHeader;
  resp: TAIHttpResponse;
  body: string;
begin
  FStreamAccum := '';
  FStreamDelta := ADelta;
  headers[0].Name := 'Authorization'; headers[0].Value := 'Bearer ' + FApiKey;
  headers[1].Name := 'Content-Type'; headers[1].Value := 'application/json';
  body := BuildRequestBody(ARequest, True);
  resp := FHttp.PostStreaming(OPENAI_CHAT_URL, headers, body, OnStreamLine, TAICancelToken(ACancel));
  if resp.StatusCode <> 200 then
    RaiseUDAWFmt(errNetwork, SUBSYS, 'OpenAI HTTP %d: %s', [resp.StatusCode, resp.Body]);
  Result.Content := FStreamAccum;
  Result.FinishReason := 'stop';
  Result.PromptTokens := 0;
  Result.CompletionTokens := 0;
end;

function IsChatCapableOpenAIModelId(const AId: string): Boolean;
begin
  Result := (StartsText('gpt-', AId) or StartsText('chatgpt', AId) or
    StartsText('o1', AId) or StartsText('o3', AId) or StartsText('o4', AId)) and
    not (ContainsText(AId, 'audio') or ContainsText(AId, 'realtime') or
    ContainsText(AId, 'transcribe') or ContainsText(AId, 'tts') or
    ContainsText(AId, 'whisper') or ContainsText(AId, 'embedding') or
    ContainsText(AId, 'moderation') or ContainsText(AId, 'dall-e') or
    ContainsText(AId, 'image') or ContainsText(AId, 'instruct'));
end;

function TOpenAIProvider.ListModels: TArray<string>;
var
  headers: array[0..0] of TAIHttpHeader;
  resp: TAIHttpResponse;
  v, data, item: TJSONValue;
  i: Integer;
  id: string;
  list: TStringList;
begin
  Result := nil;
  headers[0].Name := 'Authorization'; headers[0].Value := 'Bearer ' + FApiKey;
  try
    resp := FHttp.Get(OPENAI_MODELS_URL, headers);
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
          if IsChatCapableOpenAIModelId(id) then
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
