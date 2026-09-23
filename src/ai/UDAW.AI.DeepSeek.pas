unit UDAW.AI.DeepSeek;
{$I udaw.inc}

{ Phase 23 - DeepSeek provider. Concrete IAIProvider built on the Phase 20
  foundation (UDAW.AI.HTTP for transport, UDAW.AI.JSON for the request/
  response bodies). DeepSeek's REST API is Chat-Completions-compatible
  (same request/response shape as OpenAI's), so this mirrors
  UDAW.AI.OpenAI almost exactly, pointed at DeepSeek's endpoint and default
  model. No DeepSeek SDK is used, matching this project's from-scratch
  policy for every external format/protocol it speaks. }

interface

uses
  SysUtils, Classes, StrUtils, UDAW.Errors, UDAW.AI.Types, UDAW.AI.HTTP, UDAW.AI.JSON;

const
  DEEPSEEK_DEFAULT_MODEL = 'deepseek-chat';
  DEEPSEEK_CHAT_URL = 'https://api.deepseek.com/chat/completions';
  DEEPSEEK_MODELS_URL = 'https://api.deepseek.com/v1/models';

type
  TDeepSeekProvider = class(TInterfacedObject, IAIProvider)
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
    constructor Create(const AApiKey: string; const AModel: string = DEEPSEEK_DEFAULT_MODEL);
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
  SUBSYS = 'AI.DeepSeek';

constructor TDeepSeekProvider.Create(const AApiKey: string; const AModel: string);
begin
  inherited Create;
  FApiKey := AApiKey;
  FModel := AModel;
  if FModel = '' then FModel := DEEPSEEK_DEFAULT_MODEL;
  FHttp := TAIHttpClient.Create;
  { See UDAW.AI.Claude.pas' TClaudeProvider.Create for why this is 180s and
    not 60s: the AI-tab batch-generation flow can request up to 16384 output
    tokens, which routinely takes longer than 60s to stream back. }
  FHttp.Configure(180000);
end;

destructor TDeepSeekProvider.Destroy;
begin
  FHttp.Free;
  inherited Destroy;
end;

function TDeepSeekProvider.ProviderId: string;
begin
  Result := 'deepseek';
end;

function TDeepSeekProvider.DisplayName: string;
begin
  Result := 'DeepSeek';
end;

function TDeepSeekProvider.BuildRequestBody(const ARequest: TAIRequest; AStream: Boolean): string;
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

function TDeepSeekProvider.ParseResponse(const ABody: string): TAIResponse;
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
        RaiseUDAWFmt(errNetwork, SUBSYS, 'DeepSeek error: %s', [err.ByName('message').AsString])
      else
        RaiseUDAWFmt(errNetwork, SUBSYS, 'DeepSeek error: %s', [ABody]);
    end;
    choices := v.ByName('choices');
    if (choices = nil) or (choices.Count = 0) then
      RaiseUDAWFmt(errNetwork, SUBSYS, 'DeepSeek response had no choices: %s', [ABody]);
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

function TDeepSeekProvider.SendMessage(const ARequest: TAIRequest; ACancel: TObject): TAIResponse;
var
  headers: array[0..1] of TAIHttpHeader;
  resp: TAIHttpResponse;
  body: string;
begin
  headers[0].Name := 'Authorization'; headers[0].Value := 'Bearer ' + FApiKey;
  headers[1].Name := 'Content-Type'; headers[1].Value := 'application/json';
  body := BuildRequestBody(ARequest, False);
  resp := FHttp.Post(DEEPSEEK_CHAT_URL, headers, body, TAICancelToken(ACancel));
  if resp.StatusCode <> 200 then
    RaiseUDAWFmt(errNetwork, SUBSYS, 'DeepSeek HTTP %d: %s', [resp.StatusCode, resp.Body]);
  Result := ParseResponse(resp.Body);
end;

procedure TDeepSeekProvider.OnStreamLine(const ALine: string);
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

function TDeepSeekProvider.StreamMessage(const ARequest: TAIRequest; ADelta: TAIStreamDeltaProc;
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
  resp := FHttp.PostStreaming(DEEPSEEK_CHAT_URL, headers, body, OnStreamLine, TAICancelToken(ACancel));
  if resp.StatusCode <> 200 then
    RaiseUDAWFmt(errNetwork, SUBSYS, 'DeepSeek HTTP %d: %s', [resp.StatusCode, resp.Body]);
  Result.Content := FStreamAccum;
  Result.FinishReason := 'stop';
  Result.PromptTokens := 0;
  Result.CompletionTokens := 0;
end;

function TDeepSeekProvider.ListModels: TArray<string>;
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
    resp := FHttp.Get(DEEPSEEK_MODELS_URL, headers);
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
