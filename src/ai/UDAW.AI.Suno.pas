unit UDAW.AI.Suno;
{$I udaw.inc}

{ Explicit adapters for gcui-art/suno-api and the managed SunoAPI.org task
  contract. The caller selects a provider and supplies its base URL and key.
  Generation jobs run through UDAW.Jobs, never the UI or audio callback.
  Session cookies belong on the self-hosted proxy, not in UDAW. }

interface

uses
  SysUtils, Classes, UDAW.Errors, UDAW.AI.HTTP, UDAW.AI.JSON, UDAW.Jobs;

const
  SUNO_DEFAULT_BASE_URL = 'http://localhost:3000';
  SUNO_MANAGED_BASE_URL = 'https://apibox.erweima.ai';
  SUNO_MANAGED_DEFAULT_MODEL = 'V6';
  { Reference-audio upload for Cover/Extend (managed SunoAPI.org only - the
    self-hosted gcui-art/suno-api proxy has no equivalent contract). This is a
    fixed file-hosting host, separate from the managed generate/poll base URL
    above - checked 2026-09-19 against https://docs.sunoapi.org/file-upload-api/upload-file-base-64
    and https://docs.sunoapi.org/suno-api/upload-and-cover-audio /
    upload-and-extend-audio. }
  SUNO_UPLOAD_BASE_URL = 'https://sunoapiorg.redpandaai.co';
  SUNO_UPLOAD_PATH = '/api/file-base64-upload';
  SUNO_COVER_PATH = '/api/v1/generate/upload-cover';
  SUNO_EXTEND_PATH = '/api/v1/generate/upload-extend';
  { Recommended ceiling for the base64 upload path per the docs above - larger
    files should use multipart streaming upload, which this client does not
    implement yet. }
  SUNO_UPLOAD_MAX_BYTES = 10 * 1024 * 1024;
  { UDAW polls for results instead of hosting a webhook (see the AI tab help
    and docs/Phase24-Suno.md), so this placeholder is never actually called -
    it only satisfies the managed API's mandatory callBackUrl field. Uses the
    RFC 2606 reserved example.com domain so it can never resolve to a real
    service by accident. }
  SUNO_MANAGED_PLACEHOLDER_CALLBACK = 'https://example.com/udaw-suno-callback';
  { Total extra attempts for an idempotent GET (poll/quota check) after a
    transport-level failure - see TSunoClient.GetWithRetry. Deliberately not
    applied to the paid /generate submission. }
  SUNO_MAX_RETRIES = 1;
  { Custom-mode lyrics/prompt character cap enforced by SunoAPI.org. }
  SUNO_LYRICS_MAX_CHARS = 5000;

type
  TSunoApiKind = (sakLocalProxy, sakManaged);
  TSunoClipStatus = (scsUnknown, scsSubmitted, scsQueued, scsStreaming, scsComplete, scsError);
  { srmCover: SunoAPI.org "Upload and Cover Audio" - reinterprets RefLocalPath
      in a new style/arrangement (same melody/feel).
    srmExtend: SunoAPI.org "Upload and Extend Audio" - continues RefLocalPath
      from RefContinueAt seconds. Both are managed-API-only. }
  TSunoReferenceMode = (srmNone, srmCover, srmExtend);

  TSunoGenerationRequest = record
    Prompt: string;
    Tags: string;             // style/genre tags, e.g. 'lofi, chill'
    Title: string;
    Instrumental: Boolean;
    WaitForAudio: Boolean;    // ask the proxy to block until audio is ready
    CustomMode: Boolean;
    Model, CallbackURL: string;
    RefMode: TSunoReferenceMode;
    RefLocalPath: string;     // local recording to upload; ignored when RefMode = srmNone
    RefUploadUrl: string;     // filled in by TSunoGenerationJob.Execute after upload
    RefContinueAt: Double;    // srmExtend only: seconds into RefLocalPath to continue from
  end;

  TSunoClip = record
    Id: string;
    Status: TSunoClipStatus;
    StatusText: string;       // raw status string, for display/log
    AudioURL: string;
    Title: string;
    Tags: string;
    DurationSeconds: Double;
    ErrorMessage: string;
  end;
  TSunoClipArray = TArray<TSunoClip>;
  TSunoPollEvent = procedure(const AClips: TSunoClipArray) of object;

  TSunoClient = class
  private
    FApiKey: string;
    FBaseURL: string;
    FHttp: TAIHttpClient;
    FKind: TSunoApiKind;
    FOnPoll: TSunoPollEvent;
    function Endpoint(const APath: string): string;
    function ParseClip(const AValue: TJSONValue): TSunoClip;
    { Retries only an idempotent GET (status poll / quota check) on a
      transport-level failure (timeout, DNS, connection reset) - never on a
      response that was actually received, and never used for the paid
      /generate POST (SubmitGeneration stays single-attempt; see its own
      comment). SUNO_MAX_RETRIES=1 is the suited count for a background job
      that already re-polls every few seconds anyway: one immediate retry
      smooths over a single dropped packet without turning a truly offline
      proxy/provider into a long hang. }
    function GetWithRetry(const AUrl: string; const AHeaders: TArray<TAIHttpHeader>): TAIHttpResponse;
  public
    constructor Create(const AApiKey: string; const ABaseURL: string = SUNO_DEFAULT_BASE_URL;
      AKind: TSunoApiKind = sakLocalProxy);
    destructor Destroy; override;

    { Base URL after trailing-slash normalisation - exposed for tests and
      diagnostics logging, not used to drive requests (Endpoint does that). }
    property BaseURL: string read FBaseURL;
    property OnPoll: TSunoPollEvent read FOnPoll write FOnPoll;
    function ParseClipArray(const ABody: string): TSunoClipArray;
    { ASkipRefUploadCheck lets a caller validate a Cover/Extend request before
      the reference audio has actually been uploaded (RefUploadUrl is still
      empty at that point) - see TSunoGenerationJob.Create/Execute. }
    function GenerationBody(const ARequest: TSunoGenerationRequest;
      ASkipRefUploadCheck: Boolean = False): string;
    function GenerationPath(const ARequest: TSunoGenerationRequest): string;
    function PollPath(const AIds: TArray<string>): string;

    { Uploads a local audio file (base64) to SunoAPI.org's file host and
      returns its downloadUrl, for use as a Cover/Extend RefUploadUrl.
      Managed API only; raises if this client was created with sakLocalProxy. }
    function UploadReferenceAudio(const ALocalPath: string): string;

    { Submits one generation job. Returns the clip(s) the proxy created
      (typically two takes per prompt), each still scsSubmitted/scsQueued
      unless ARequest.WaitForAudio was set and the proxy honours it. }
    function SubmitGeneration(const ARequest: TSunoGenerationRequest): TSunoClipArray;

    { One-shot status poll for a set of clip ids. }
    function PollClips(const AIds: TArray<string>): TSunoClipArray;

    { Polls PollClips on APollIntervalMs until every clip is scsComplete or
      scsError, or ATimeoutMs elapses (whichever first). Returns the last
      poll's clip array - callers should check each clip's Status. }
    function WaitForCompletion(const AIds: TArray<string>;
      ATimeoutMs: Integer = 180000; APollIntervalMs: Integer = 3000): TSunoClipArray;

    { Downloads a clip's finished audio (Suno serves MP3) to AOutFile.
      Raises on a non-2xx response or empty body. }
    procedure DownloadAudio(const AAudioURL, AOutFile: string);

    { Lightweight reachability/auth check for the "Test" button: hits the
      proxy's poll endpoint with an empty id list (cheap on every known
      suno-api build - it just returns an empty/short response, never
      triggers a generation job) and classifies the outcome. A network-level
      failure (proxy not running, wrong host) is reported distinctly from a
      reachable-but-rejected-key (401) or reachable-but-broken (5xx) proxy,
      so the log line actually tells the user what to fix. }
    function CheckConnection(out AMessage: string): Boolean;
  end;

  TSunoAsset = record
    Path, Title: string;
    SampleRate, Channels: Integer;
    Frames: Int64;
  end;
  TSunoAssets = TArray<TSunoAsset>;
  TSunoGenerationJob = class(TJob)
  private
    FClient: TSunoClient;
    FRequest: TSunoGenerationRequest;
    FOutputDir: string;
    FAssets: TSunoAssets;
    procedure PollProgress(const AClips: TSunoClipArray);
  protected
    function Execute: Boolean; override;
  public
    { AOutputDir is where finished takes are saved as named .wav files - pass
      the user's Recordings folder so generated audio lives alongside their
      other captured takes. Empty falls back to Data\Suno. }
    constructor Create(const AKey, AURL: string; AKind: TSunoApiKind;
      const ARequest: TSunoGenerationRequest; const AOutputDir: string = '');
    destructor Destroy; override;
    property Assets: TSunoAssets read FAssets;
  end;

function SunoClipStatusFromText(const AText: string): TSunoClipStatus;
{ Sanitizes a title into a safe cross-platform filename component - also
  used outside the Suno pipeline (e.g. the Tracker Instruments tab) for the
  same "make this name safe to write to disk" need. }
function SafeSunoFileName(const ATitle: string): string;

implementation

uses UDAW.Paths, UDAW.Codec.MP3, UDAW.Codec.MP3.Decoder, UDAW.Codec.WAV,
  UDAW.SecureStorage;

const
  SUBSYS = 'AI.Suno';

function SunoClipStatusFromText(const AText: string): TSunoClipStatus;
var
  s: string;
begin
  s := LowerCase(Trim(AText));
  if s = 'submitted' then Result := scsSubmitted
  else if (s = 'queued') or (s = 'pending') or (s = 'processing') then Result := scsQueued
  else if (s = 'streaming') or (s = 'text_success') or (s = 'first_success') then Result := scsStreaming
  else if (s = 'complete') or (s = 'completed') or (s = 'success') then Result := scsComplete
  else if (s = 'error') or (s = 'failed') or (Pos('_failed', s) > 0) or
    (s = 'callback_exception') or (s = 'sensitive_word_error') then Result := scsError
  else Result := scsUnknown;
end;

constructor TSunoClient.Create(const AApiKey: string; const ABaseURL: string; AKind: TSunoApiKind);
begin
  inherited Create;
  FApiKey := AApiKey;
  FKind := AKind;
  FBaseURL := Trim(ABaseURL);
  if FBaseURL = '' then
    if FKind = sakManaged then FBaseURL := SUNO_MANAGED_BASE_URL
    else FBaseURL := SUNO_DEFAULT_BASE_URL;
  while (Length(FBaseURL) > 0) and (FBaseURL[Length(FBaseURL)] = '/') do
    Delete(FBaseURL, Length(FBaseURL), 1);
  if not ((Pos('http://', LowerCase(FBaseURL)) = 1) or
    (Pos('https://', LowerCase(FBaseURL)) = 1)) or
    (Pos('@', FBaseURL) > 0) or (Pos('?', FBaseURL) > 0) or (Pos('#', FBaseURL) > 0) then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'Use an HTTP(S) API base URL without embedded credentials, query or fragment.');
  FHttp := TAIHttpClient.Create;
  FHttp.Configure(30000);
end;

function TSunoClient.GetWithRetry(const AUrl: string; const AHeaders: TArray<TAIHttpHeader>): TAIHttpResponse;
var
  attempt: Integer;
begin
  for attempt := 1 to SUNO_MAX_RETRIES + 1 do
  begin
    try
      Exit(FHttp.Get(AUrl, AHeaders));
    except
      on E: Exception do
      begin
        if attempt > SUNO_MAX_RETRIES then raise;
        Sleep(500);
      end;
    end;
  end;
end;

destructor TSunoClient.Destroy;
begin
  FHttp.Free;
  inherited Destroy;
end;

function TSunoClient.Endpoint(const APath: string): string;
begin
  Result := FBaseURL + APath;
end;

function TSunoClient.ParseClip(const AValue: TJSONValue): TSunoClip;
begin
  Result.Id := '';
  Result.Status := scsUnknown;
  Result.StatusText := '';
  Result.AudioURL := '';
  Result.Title := '';
  Result.Tags := '';
  Result.DurationSeconds := 0;
  Result.ErrorMessage := '';
  if AValue = nil then Exit;
  if AValue.HasName('id') then Result.Id := AValue.ByName('id').AsString;
  if AValue.HasName('status') then
  begin
    Result.StatusText := AValue.ByName('status').AsString;
    Result.Status := SunoClipStatusFromText(Result.StatusText);
  end;
  if AValue.HasName('audio_url') then Result.AudioURL := AValue.ByName('audio_url').AsString;
  if AValue.HasName('title') then Result.Title := AValue.ByName('title').AsString;
  if AValue.HasName('tags') then Result.Tags := AValue.ByName('tags').AsString;
  if AValue.HasName('duration') then Result.DurationSeconds := AValue.ByName('duration').AsNumber;
  if AValue.HasName('error_message') then Result.ErrorMessage := AValue.ByName('error_message').AsString;
  if (Result.AudioURL = '') and AValue.HasName('audioUrl') then
    Result.AudioURL := AValue.ByName('audioUrl').AsString;
  if Result.Id = '' then RaiseUDAW(errParse, SUBSYS, 'Provider returned a clip without an ID.');
  { Streaming URLs are not evidence of completion. }
end;

function TSunoClient.ParseClipArray(const ABody: string): TSunoClipArray;
var
  v, err, data, arr: TJSONValue;
  state, taskId: string;
  i: Integer;
begin
  Result := nil;
  v := Parse(ABody);
  try
    if v.HasName('code') and (v.ByName('code').AsNumber <> 200) then
      RaiseUDAWFmt(errNetwork, SUBSYS, 'Provider rejected request (code %s). Check credentials, credits and settings.',
        [v.ByName('code').ToJSONString]);
    if FKind = sakManaged then
    begin
      if not v.HasName('code') or not v.HasName('data') then
        RaiseUDAW(errParse, SUBSYS, 'Expected managed API response envelope.');
      data := v.ByName('data');
      if not data.HasName('taskId') then RaiseUDAW(errParse, SUBSYS, 'No task ID in managed response.');
      taskId := data.ByName('taskId').AsString;
      if taskId = '' then RaiseUDAW(errParse, SUBSYS, 'Empty managed task ID.');
      state := '';
      if data.HasName('status') then state := data.ByName('status').AsString;
      if SunoClipStatusFromText(state) = scsComplete then
      begin
        arr := nil;
        if data.HasName('response') then arr := data.ByName('response').ByName('sunoData');
        if (arr = nil) or (arr.Kind <> jkArray) or (arr.Count = 0) then
          RaiseUDAW(errParse, SUBSYS, 'Completed task contains no audio clips.');
        SetLength(Result, arr.Count);
        for i := 0 to arr.Count - 1 do
        begin
          Result[i] := ParseClip(arr.Items[i]);
          Result[i].Status := scsComplete;
          Result[i].StatusText := state;
        end;
      end
      else
      begin
        SetLength(Result, 1);
        Result[0].Id := taskId;
        Result[0].StatusText := state;
        Result[0].Status := SunoClipStatusFromText(state);
        if state = '' then Result[0].Status := scsSubmitted;
      end;
      Exit;
    end;
    if v.HasName('error') and (v.ByName('error').Kind <> jkNull) then
    begin
      err := v.ByName('error');
      if (err <> nil) and err.HasName('message') then
        RaiseUDAWFmt(errNetwork, SUBSYS, 'Suno error: %s', [err.ByName('message').AsString])
      else
        RaiseUDAW(errNetwork, SUBSYS, 'Proxy reported an API error. Check its session and server log.');
    end;
    if v.Kind = jkArray then
    begin
      SetLength(Result, v.Count);
      for i := 0 to v.Count - 1 do
        Result[i] := ParseClip(v.Items[i]);
    end
    else
    begin
      // some proxy builds wrap the array as {"clips": [...]}
      if v.HasName('clips') and (v.ByName('clips').Kind = jkArray) then
      begin
        SetLength(Result, v.ByName('clips').Count);
        for i := 0 to v.ByName('clips').Count - 1 do
          Result[i] := ParseClip(v.ByName('clips').Items[i]);
      end
      else
      begin
        SetLength(Result, 1);
        Result[0] := ParseClip(v);
      end;
    end;
  finally
    v.Free;
  end;
end;

function TSunoClient.GenerationPath(const ARequest: TSunoGenerationRequest): string;
begin
  case ARequest.RefMode of
    srmCover:  Exit(SUNO_COVER_PATH);
    srmExtend: Exit(SUNO_EXTEND_PATH);
  end;
  if FKind = sakManaged then Result := '/api/v1/generate'
  else if ARequest.CustomMode then Result := '/api/custom_generate'
  else Result := '/api/generate';
end;

function TSunoClient.GenerationBody(const ARequest: TSunoGenerationRequest;
  ASkipRefUploadCheck: Boolean): string;
var root: TJSONValue;
begin
  if ARequest.RefMode <> srmNone then
  begin
    if FKind <> sakManaged then
      RaiseUDAW(errInvalidArgument, SUBSYS, 'Cover/Extend need the managed SunoAPI.org API - switch API type first.');
    if Trim(ARequest.Model) = '' then
      RaiseUDAW(errInvalidArgument, SUBSYS, 'Cover/Extend need a model.');
    if Pos('https://', LowerCase(ARequest.CallbackURL)) <> 1 then
      RaiseUDAW(errInvalidArgument, SUBSYS, 'Cover/Extend need your public HTTPS callback URL.');
    if (not ASkipRefUploadCheck) and (Trim(ARequest.RefUploadUrl) = '') then
      RaiseUDAW(errInvalidArgument, SUBSYS, 'Reference audio has not been uploaded yet.');
    if (ARequest.RefMode = srmExtend) and (ARequest.RefContinueAt < 0) then
      RaiseUDAW(errInvalidArgument, SUBSYS, 'Extend needs a continue-from time of 0 seconds or more.');
    { Cover: CustomMode + non-instrumental needs prompt/style/title; instrumental
      needs style/title. Extend: only in "custom" (defaultParamFlag=False) mode
      does style/title become required - see docs referenced above. }
    if (ARequest.RefMode = srmCover) and ARequest.CustomMode then
    begin
      if (Trim(ARequest.Tags) = '') or (Trim(ARequest.Title) = '') then
        RaiseUDAW(errInvalidArgument, SUBSYS, 'Custom mode requires style tags and title.');
      if (not ARequest.Instrumental) and (Trim(ARequest.Prompt) = '') then
        RaiseUDAW(errInvalidArgument, SUBSYS, 'Enter a music description or custom lyrics.');
    end;
    if (ARequest.RefMode = srmExtend) and (not ARequest.CustomMode) and
      ((Trim(ARequest.Tags) = '') or (Trim(ARequest.Title) = '')) then
      RaiseUDAW(errInvalidArgument, SUBSYS, 'Custom mode requires style tags and title.');
    root := JSONObject;
    try
      root.AddPair('uploadUrl', JSONString(ARequest.RefUploadUrl));
      root.AddPair('model', JSONString(ARequest.Model));
      root.AddPair('callBackUrl', JSONString(ARequest.CallbackURL));
      if ARequest.RefMode = srmCover then
      begin
        root.AddPair('customMode', JSONBool(ARequest.CustomMode));
        root.AddPair('instrumental', JSONBool(ARequest.Instrumental));
        if ARequest.CustomMode then
        begin
          root.AddPair('style', JSONString(ARequest.Tags));
          root.AddPair('title', JSONString(ARequest.Title));
          if not ARequest.Instrumental then root.AddPair('prompt', JSONString(ARequest.Prompt));
        end
        else if Trim(ARequest.Prompt) <> '' then
          root.AddPair('prompt', JSONString(ARequest.Prompt));
      end
      else // srmExtend
      begin
        root.AddPair('defaultParamFlag', JSONBool(not ARequest.CustomMode));
        root.AddPair('continueAt', JSONNumber(ARequest.RefContinueAt));
        if ARequest.CustomMode then
        begin
          root.AddPair('style', JSONString(ARequest.Tags));
          root.AddPair('title', JSONString(ARequest.Title));
          root.AddPair('instrumental', JSONBool(ARequest.Instrumental));
          if Trim(ARequest.Prompt) <> '' then root.AddPair('prompt', JSONString(ARequest.Prompt));
        end;
      end;
      Exit(root.ToJSONString);
    finally root.Free; end;
  end;

  if (Trim(ARequest.Prompt) = '') and not (ARequest.CustomMode and ARequest.Instrumental) then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'Enter a music description or custom lyrics.');
  if ARequest.CustomMode and ((Trim(ARequest.Tags) = '') or (Trim(ARequest.Title) = '')) then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'Custom mode requires style tags and title.');
  if ARequest.CustomMode and (Length(ARequest.Prompt) > SUNO_LYRICS_MAX_CHARS) then
    RaiseUDAW(errInvalidArgument, SUBSYS, Format('Custom lyrics exceed the %d character Suno limit.', [SUNO_LYRICS_MAX_CHARS]));
  if (FKind = sakManaged) and ((Trim(FApiKey) = '') or (Trim(ARequest.Model) = '') or
    (Pos('https://', LowerCase(ARequest.CallbackURL)) <> 1)) then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'Managed API needs its API key, model and your public HTTPS callback URL.');
  root := JSONObject;
  try
    root.AddPair('prompt', JSONString(ARequest.Prompt));
    if FKind = sakManaged then
    begin
      root.AddPair('customMode', JSONBool(ARequest.CustomMode));
      root.AddPair('instrumental', JSONBool(ARequest.Instrumental));
      root.AddPair('model', JSONString(ARequest.Model));
      root.AddPair('callBackUrl', JSONString(ARequest.CallbackURL));
      if ARequest.CustomMode then root.AddPair('style', JSONString(ARequest.Tags));
    end
    else
    begin
      root.AddPair('make_instrumental', JSONBool(ARequest.Instrumental));
      root.AddPair('wait_audio', JSONBool(ARequest.WaitForAudio));
      if ARequest.CustomMode then root.AddPair('tags', JSONString(ARequest.Tags));
    end;
    if ARequest.CustomMode then root.AddPair('title', JSONString(ARequest.Title));
    Result := root.ToJSONString;
  finally root.Free; end;
end;

function TSunoClient.SubmitGeneration(const ARequest: TSunoGenerationRequest): TSunoClipArray;
var
  headers: TArray<TAIHttpHeader>;
  resp: TAIHttpResponse;
  body: string;
begin
  SetLength(headers, 1);
  headers[0].Name := 'Content-Type'; headers[0].Value := 'application/json';
  if FApiKey <> '' then
  begin
    SetLength(headers, 2);
    headers[1].Name := 'Authorization'; headers[1].Value := 'Bearer ' + FApiKey;
  end;
  body := GenerationBody(ARequest);
  resp := FHttp.Post(Endpoint(GenerationPath(ARequest)), headers, body);
  if (resp.StatusCode < 200) or (resp.StatusCode >= 300) then
    RaiseUDAWFmt(errNetwork, SUBSYS, 'Suno generate HTTP %d. Not retried; check provider history before resubmitting.', [resp.StatusCode]);
  Result := ParseClipArray(resp.Body);
end;

function TSunoClient.PollPath(const AIds: TArray<string>): string;
var id: string; b: Byte; bytes: TBytes;
begin
  if (Length(AIds) = 0) or ((FKind = sakManaged) and (Length(AIds) <> 1)) then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'Supply clip IDs or one managed task ID.');
  Result := '';
  for id in AIds do
  begin
    if Trim(id) = '' then RaiseUDAW(errInvalidArgument, SUBSYS, 'Empty generation ID.');
    if Result <> '' then Result := Result + ',';
    bytes := TEncoding.UTF8.GetBytes(id);
    for b in bytes do
      if b in [48..57, 65..90, 97..122, 45, 46, 95, 126] then Result := Result + Char(b)
      else Result := Result + '%' + IntToHex(b, 2);
  end;
  if FKind = sakManaged then Result := '/api/v1/generate/record-info?taskId=' + Result
  else Result := '/api/get?ids=' + Result;
end;

function TSunoClient.PollClips(const AIds: TArray<string>): TSunoClipArray;
var
  headers: TArray<TAIHttpHeader>;
  resp: TAIHttpResponse;
begin
  if FApiKey <> '' then
  begin
    SetLength(headers, 1);
    headers[0].Name := 'Authorization'; headers[0].Value := 'Bearer ' + FApiKey;
  end;
  resp := GetWithRetry(Endpoint(PollPath(AIds)), headers);
  if (resp.StatusCode < 200) or (resp.StatusCode >= 300) then
    RaiseUDAWFmt(errNetwork, SUBSYS, 'Suno poll HTTP %d. Check provider history before generating again.', [resp.StatusCode]);
  Result := ParseClipArray(resp.Body);
end;

function AllClipsSettled(const AClips: TSunoClipArray): Boolean;
var
  i: Integer;
begin
  Result := Length(AClips) > 0;
  for i := 0 to High(AClips) do
    if not (AClips[i].Status in [scsComplete, scsError]) then
      Exit(False);
end;

function TSunoClient.WaitForCompletion(const AIds: TArray<string>;
  ATimeoutMs, APollIntervalMs: Integer): TSunoClipArray;
var
  started: UInt64;
  interval, delay, i, j: Integer;
  complete, found: Boolean;
begin
  if ATimeoutMs <= 0 then RaiseUDAW(errInvalidArgument, SUBSYS, 'Timeout must be positive.');
  started := TThread.GetTickCount64;
  interval := APollIntervalMs;
  if interval < 200 then interval := 200;
  Result := nil;
  repeat
    if Assigned(FOnPoll) then FOnPoll(Result);
    Result := PollClips(AIds);
    if Assigned(FOnPoll) then FOnPoll(Result);
    complete := AllClipsSettled(Result);
    if (FKind = sakLocalProxy) and complete then
      for i := 0 to High(AIds) do
      begin
        found := False;
        for j := 0 to High(Result) do if Result[j].Id = AIds[i] then found := True;
        if not found then complete := False;
      end;
    if complete then Exit;
    delay := interval;
    while delay > 0 do
    begin
      if TThread.GetTickCount64 - started >= UInt64(ATimeoutMs) then
        RaiseUDAW(errTimeout, SUBSYS, 'Generation timed out. Check provider history before submitting another paid request.');
      if Assigned(FOnPoll) then FOnPoll(Result);
      Sleep(100); Dec(delay, 100);
    end;
  until False;
end;

function TSunoClient.CheckConnection(out AMessage: string): Boolean;
var
  headers: TArray<TAIHttpHeader>;
  resp: TAIHttpResponse;
  path: string;
  v: TJSONValue;
begin
  if FApiKey <> '' then
  begin
    SetLength(headers, 1);
    headers[0].Name := 'Authorization'; headers[0].Value := 'Bearer ' + FApiKey;
  end;
  try
    if FKind = sakManaged then path := '/api/v1/generate/credit' else path := '/api/get_limit';
    resp := GetWithRetry(Endpoint(path), headers);
    if (resp.StatusCode < 200) or (resp.StatusCode >= 300) then
    begin
      AMessage := Format('Connection test failed: HTTP %d. Check API type, URL and credentials.', [resp.StatusCode]);
      Exit(False);
    end;
    v := Parse(resp.Body);
    try
      if FKind = sakManaged then
      begin
        if not v.HasName('code') or (v.ByName('code').AsNumber <> 200) or
          not v.HasName('data') or (v.ByName('data').Kind <> jkNumber) then
          RaiseUDAW(errParse, SUBSYS, 'Expected successful managed credit response.');
        AMessage := 'Connected. Credits: ' + v.ByName('data').ToJSONString;
      end
      else
      begin
        if not v.HasName('credits_left') or (v.ByName('credits_left').Kind <> jkNumber) then
          RaiseUDAW(errParse, SUBSYS, 'Expected numeric proxy quota response.');
        AMessage := 'Connected. Credits: ' + v.ByName('credits_left').ToJSONString;
      end;
    finally v.Free; end;
    Exit(True);
  except
    on E: Exception do
    begin
      AMessage := 'Connection test failed: ' + E.Message;
      Exit(False);
    end;
  end;
end;

procedure TSunoClient.DownloadAudio(const AAudioURL, AOutFile: string);
var
  headers: array[0..0] of TAIHttpHeader;
  data: TBytes;
  status: Integer;
  fs: TFileStream;
begin
  if not ((Pos('https://', LowerCase(AAudioURL)) = 1) or
    (Pos('http://', LowerCase(AAudioURL)) = 1)) then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'Audio URL must use HTTP(S).');
  headers[0].Name := 'Accept'; headers[0].Value := 'audio/mpeg, application/octet-stream, */*';
  data := FHttp.GetBytes(AAudioURL, headers, status);
  if (status < 200) or (status >= 300) then
    RaiseUDAWFmt(errNetwork, SUBSYS, 'Suno audio download HTTP %d', [status]);
  if Length(data) = 0 then
    RaiseUDAW(errNetwork, SUBSYS, 'Suno audio download returned an empty body');
  fs := TFileStream.Create(AOutFile, fmCreate);
  try
    fs.WriteBuffer(data[0], Length(data));
  finally
    fs.Free;
  end;
end;

function TSunoClient.UploadReferenceAudio(const ALocalPath: string): string;
var
  headers: TArray<TAIHttpHeader>;
  resp: TAIHttpResponse;
  fs: TFileStream;
  bytes: TBytes;
  root: TJSONValue;
  v, data: TJSONValue;
begin
  if FKind <> sakManaged then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'Reference audio upload needs the managed SunoAPI.org API.');
  if Trim(FApiKey) = '' then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'Reference audio upload needs your SunoAPI.org key.');
  if not FileExists(ALocalPath) then
    RaiseUDAWFmt(errInvalidArgument, SUBSYS, 'File not found: %s', [ALocalPath]);

  fs := TFileStream.Create(ALocalPath, fmOpenRead or fmShareDenyWrite);
  try
    if fs.Size > SUNO_UPLOAD_MAX_BYTES then
      RaiseUDAWFmt(errInvalidArgument, SUBSYS,
        'Reference file is %d MB; the base64 upload path supports up to %d MB.',
        [fs.Size div (1024 * 1024), SUNO_UPLOAD_MAX_BYTES div (1024 * 1024)]);
    SetLength(bytes, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(bytes[0], fs.Size);
  finally
    fs.Free;
  end;

  root := JSONObject;
  try
    root.AddPair('base64Data', JSONString(UDAW.SecureStorage.Base64Encode(bytes)));
    root.AddPair('uploadPath', JSONString('udaw-reference'));
    root.AddPair('fileName', JSONString(ExtractFileName(ALocalPath)));

    SetLength(headers, 2);
    headers[0].Name := 'Content-Type'; headers[0].Value := 'application/json';
    headers[1].Name := 'Authorization'; headers[1].Value := 'Bearer ' + FApiKey;
    resp := FHttp.Post(SUNO_UPLOAD_BASE_URL + SUNO_UPLOAD_PATH, headers, root.ToJSONString);
  finally
    root.Free;
  end;
  if (resp.StatusCode < 200) or (resp.StatusCode >= 300) then
    RaiseUDAWFmt(errNetwork, SUBSYS, 'Reference audio upload HTTP %d.', [resp.StatusCode]);

  v := Parse(resp.Body);
  try
    if not v.HasName('success') or not v.ByName('success').AsBool then
      RaiseUDAW(errNetwork, SUBSYS, 'Reference audio upload was rejected by the provider.');
    if not v.HasName('data') then RaiseUDAW(errParse, SUBSYS, 'Upload response has no data.');
    data := v.ByName('data');
    if not data.HasName('downloadUrl') then RaiseUDAW(errParse, SUBSYS, 'Upload response has no downloadUrl.');
    Result := data.ByName('downloadUrl').AsString;
    if Result = '' then RaiseUDAW(errParse, SUBSYS, 'Upload response has an empty downloadUrl.');
  finally
    v.Free;
  end;
end;

constructor TSunoGenerationJob.Create(const AKey, AURL: string; AKind: TSunoApiKind;
  const ARequest: TSunoGenerationRequest; const AOutputDir: string = '');
begin
  inherited Create('Suno music generation');
  FRequest := ARequest;
  FOutputDir := Trim(AOutputDir);
  if (FRequest.RefMode <> srmNone) and not FileExists(FRequest.RefLocalPath) then
    RaiseUDAWFmt(errInvalidArgument, SUBSYS, 'Reference recording not found: %s', [FRequest.RefLocalPath]);
  FClient := TSunoClient.Create(AKey, AURL, AKind);
  FClient.GenerationBody(FRequest, True);
  FClient.OnPoll := PollProgress;
end;

destructor TSunoGenerationJob.Destroy;
begin
  FClient.Free;
  inherited Destroy;
end;

procedure TSunoGenerationJob.PollProgress(const AClips: TSunoClipArray);
var c: TSunoClip; s: string;
begin
  ThrowIfCancelled;
  s := 'Waiting for provider';
  for c in AClips do s := s + ' | ' + c.Id + ': ' + c.StatusText;
  SetProgress(0, s); // no generation percentage is supplied by the provider
end;

{ Sanitizes a clip title into a safe filename component: strips characters
  that are illegal (or awkward) in Windows/macOS/Linux filenames and trims
  it to a sane length. Falls back to 'Suno Take' if nothing usable remains. }
function SafeSunoFileName(const ATitle: string): string;
const
  BAD_CHARS: set of AnsiChar = ['\', '/', ':', '*', '?', '"', '<', '>', '|',
    #0..#31];
var
  i: Integer;
  ch: Char;
begin
  Result := '';
  for i := 1 to Length(ATitle) do
  begin
    ch := ATitle[i];
    if CharInSet(ch, BAD_CHARS) then Continue;
    Result := Result + ch;
  end;
  Result := Trim(Result);
  while (Result <> '') and (Result[Length(Result)] = '.') do
    Delete(Result, Length(Result), 1);
  if Length(Result) > 80 then Result := Copy(Result, 1, 80);
  if Result = '' then Result := 'Suno Take';
end;

{ Generated takes are real paid output and must survive as long as any
  project references them, so they land in AOutputDir (the user's Recordings
  folder, alongside their other captured takes) or, if that isn't known,
  under the durable Data root - never under Cache (a location the OS,
  cleanup tools, or the user can legitimately treat as disposable) and never
  keyed by an opaque GUID the user has no way to identify. }
function UniqueSunoWavPath(const ATitle, AOutputDir: string): string;
var
  base, dir, candidate: string;
  n: Integer;
begin
  dir := AOutputDir;
  if dir = '' then dir := DataFile('Suno');
  dir := IncludeTrailingPathDelimiter(dir);
  ForceDirectories(dir);
  base := SafeSunoFileName(ATitle);
  candidate := dir + base + '.wav';
  n := 1;
  while FileExists(candidate) do
  begin
    Inc(n);
    candidate := dir + base + ' (' + IntToStr(n) + ').wav';
  end;
  Result := candidate;
end;

function TSunoGenerationJob.Execute: Boolean;
var clips: TSunoClipArray; ids: TArray<string>; i, n: Integer;
  mp3Path, wavPath: string; g: TGUID; decoded: TMP3DecodeResult;
begin
  ThrowIfCancelled;
  if FRequest.RefMode <> srmNone then
  begin
    SetProgress(0, 'Uploading reference audio');
    FRequest.RefUploadUrl := FClient.UploadReferenceAudio(FRequest.RefLocalPath);
    ThrowIfCancelled;
  end;
  SetProgress(0, 'Submitting prompt');
  clips := FClient.SubmitGeneration(FRequest);
  if Length(clips) = 0 then RaiseUDAW(errParse, SUBSYS, 'Generation returned no IDs.');
  SetLength(ids, Length(clips));
  for i := 0 to High(clips) do ids[i] := clips[i].Id;
  if not AllClipsSettled(clips) then clips := FClient.WaitForCompletion(ids, 600000, 3000);
  for i := 0 to High(clips) do
  begin
    ThrowIfCancelled;
    if clips[i].Status = scsError then
      RaiseUDAW(errNetwork, SUBSYS, 'Provider generation failed: ' + clips[i].StatusText);
    if clips[i].AudioURL = '' then RaiseUDAW(errParse, SUBSYS, 'Completed clip has no audio URL.');
    CreateGUID(g); // download scratch file only - never kept, so a GUID name is fine here
    mp3Path := CacheFile('suno' + PathDelim + GUIDToString(g) + '.mp3');
    wavPath := UniqueSunoWavPath(clips[i].Title, FOutputDir);
    ForceDirectories(ExtractFilePath(mp3Path));
    try
      SetProgress(i / Length(clips), Format('Downloading take %d of %d', [i + 1, Length(clips)]));
      FClient.DownloadAudio(clips[i].AudioURL, mp3Path);
      ThrowIfCancelled;
      SetProgress(i / Length(clips), Format('Decoding take %d of %d', [i + 1, Length(clips)]));
      if not Mp3DecodeFile(mp3Path, decoded) or (decoded.Frames <= 0) or
        (decoded.SampleRate <= 0) or (decoded.Frames > High(Integer)) then
        RaiseUDAW(errParse, SUBSYS, 'Generated audio is not a supported valid MP3.');
      ThrowIfCancelled;
      SaveWavFile(wavPath, decoded.Pcm, decoded.Channels, decoded.SampleRate,
        Integer(decoded.Frames), wsfPCM16, False);
      n := Length(FAssets); SetLength(FAssets, n + 1);
      FAssets[n].Path := wavPath; FAssets[n].Title := clips[i].Title;
      FAssets[n].SampleRate := decoded.SampleRate; FAssets[n].Channels := decoded.Channels;
      FAssets[n].Frames := decoded.Frames;
    finally DeleteFile(mp3Path); end;
  end;
  ThrowIfCancelled;
  SetProgress(1, 'Audio ready for timeline import');
  Result := True;
end;

end.
