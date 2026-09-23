unit UDAW.AI.Luma;
{$I udaw.inc}

{ Luma AI (Dream Machine API) client - VIDEO and IMAGE generation only.

  Verified 2026-09-21 against https://docs.lumalabs.ai (create/get generation,
  generate image, credits). Luma's developer API has NO music, sound or
  sheet-music endpoint (the only audio call is "add audio to a generation",
  not implemented here as its request contract could not be confirmed), so
  LumaCapabilities reports music/lyrics/instrumental/sheet-music as
  unsupported. The AI tab uses that record to show only the controls Luma
  actually accepts and hide the music-only ones.

  Contract: Base https://api.lumalabs.ai/dream-machine/v1, Bearer key.
  POST /generations/video | /generations/image -> id + state; poll
  GET /generations/ID until state is completed|failed; GET /credits
  -> credit_balance (USD cents). Requests are asynchronous and paid, so
  submission is single-attempt (never retried), like Suno's. }

interface

uses
  SysUtils, Classes, UDAW.Errors, UDAW.AI.HTTP, UDAW.AI.JSON, UDAW.Jobs;

const
  LUMA_BASE_URL = 'https://api.lumalabs.ai/dream-machine/v1';

type
  TLumaMediaKind = (lmkVideo, lmkImage);
  TLumaState = (lsUnknown, lsQueued, lsDreaming, lsCompleted, lsFailed);

  { What a Luma media kind accepts - drives control visibility in the UI. }
  TLumaCapabilities = record
    Prompt, AspectRatio, Resolution, Duration, Loop, Keyframes,
    Concepts, Format, ImageRef, StyleRef, CharacterRef, ModifyRef: Boolean;
    { Not offered by Luma at all - always False, listed so the UI has one
      place to ask "does this provider do music / a printed score?". }
    Music, Lyrics, Instrumental, SheetMusic: Boolean;
    Models: TArray<string>;
  end;

  TLumaRequest = record
    Kind: TLumaMediaKind;
    Model: string;
    Prompt: string;
    AspectRatio: string;      // '' = API default (16:9)
    Resolution: string;       // video only: 540p|720p|1080p|4k
    Duration: string;         // video only: 5s|9s
    Loop: Boolean;            // video only
    StartFrameUrl: string;    // video only: keyframes.frame0 image URL
    EndFrameUrl: string;      // video only: keyframes.frame1 image URL
    Concepts: TArray<string>; // video only: camera concept keys (see GetConcepts)
    ImageFormat: string;      // image only: jpg|png
    ImageRefUrl: string;      // image only
    ImageRefWeight: Double;   // 0..1, 0 = API default
    StyleRefUrl: string;      // image only
    StyleRefWeight: Double;
    CharacterRefUrl: string;  // image only
    ModifyRefUrl: string;     // image only: modify_image_ref
    ModifyRefWeight: Double;
  end;

  TLumaGeneration = record
    Id: string;
    State: TLumaState;
    StateText, FailureReason, VideoUrl, ImageUrl: string;
  end;

  TLumaPollEvent = procedure(const AGen: TLumaGeneration) of object;

  TLumaClient = class
  private
    FApiKey: string;
    FHttp: TAIHttpClient;
    FOnPoll: TLumaPollEvent;
    function Headers: TArray<TAIHttpHeader>;
    function ParseGeneration(const ABody: string): TLumaGeneration;
  public
    constructor Create(const AApiKey: string);
    destructor Destroy; override;
    property OnPoll: TLumaPollEvent read FOnPoll write FOnPoll;

    function RequestBody(const ARequest: TLumaRequest): string;
    function Submit(const ARequest: TLumaRequest): TLumaGeneration;
    function Poll(const AId: string): TLumaGeneration;
    function WaitForCompletion(const AId: string; ATimeoutMs: Integer = 600000;
      APollIntervalMs: Integer = 3000): TLumaGeneration;
    { Credit balance in USD cents; doubles as the key/connection test. }
    function GetCreditsCents: Double;
    { Camera concept keys valid for video (GET /generations/concepts/list). }
    function GetConcepts: TArray<string>;
    procedure Download(const AUrl, AOutFile: string);
  end;

  { Background generation job (submit -> poll -> download), run through
    UDAW.Jobs like the Suno job - never on the UI or audio thread. The
    finished file (.mp4 / .jpg / .png) is saved to AOutputDir. }
  TLumaGenerationJob = class(TJob)
  private
    FClient: TLumaClient;
    FRequest: TLumaRequest;
    FOutputDir: string;
    FOutputPath: string;
    procedure PollProgress(const AGen: TLumaGeneration);
  protected
    function Execute: Boolean; override;
  public
    constructor Create(const AKey: string; const ARequest: TLumaRequest; const AOutputDir: string);
    destructor Destroy; override;
    property OutputPath: string read FOutputPath;
    function IsVideo: Boolean;
    { Requested clip length in seconds (5s/9s; video only, else 0). }
    function DurationSeconds: Double;
  end;

function LumaCapabilities(AKind: TLumaMediaKind): TLumaCapabilities;
function LumaStateFromText(const AText: string): TLumaState;

implementation

const
  SUBSYS = 'AI.Luma';

function LumaCapabilities(AKind: TLumaMediaKind): TLumaCapabilities;
begin
  Result := Default(TLumaCapabilities);
  Result.Prompt := True;
  Result.AspectRatio := True;
  if AKind = lmkVideo then
  begin
    Result.Resolution := True;
    Result.Duration := True;
    Result.Loop := True;
    Result.Keyframes := True;
    Result.Concepts := True;
    Result.Models := ['ray-2', 'ray-flash-2'];
  end
  else
  begin
    Result.Format := True;
    Result.ImageRef := True;
    Result.ModifyRef := True;
    Result.StyleRef := True;
    Result.CharacterRef := True;
    Result.Models := ['photon-1', 'photon-flash-1'];
  end;
end;

function LumaStateFromText(const AText: string): TLumaState;
var
  s: string;
begin
  s := LowerCase(Trim(AText));
  if s = 'queued' then Result := lsQueued
  else if s = 'dreaming' then Result := lsDreaming
  else if s = 'completed' then Result := lsCompleted
  else if s = 'failed' then Result := lsFailed
  else Result := lsUnknown;
end;

function OneOf(const AValue: string; const AAllowed: array of string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(AAllowed) do
    if AValue = AAllowed[i] then Exit(True);
  Result := False;
end;

constructor TLumaClient.Create(const AApiKey: string);
begin
  inherited Create;
  FApiKey := Trim(AApiKey);
  FHttp := TAIHttpClient.Create;
  FHttp.Configure(30000);
end;

destructor TLumaClient.Destroy;
begin
  FHttp.Free;
  inherited Destroy;
end;

function TLumaClient.Headers: TArray<TAIHttpHeader>;
begin
  SetLength(Result, 3);
  Result[0].Name := 'Authorization'; Result[0].Value := 'Bearer ' + FApiKey;
  Result[1].Name := 'Accept'; Result[1].Value := 'application/json';
  Result[2].Name := 'Content-Type'; Result[2].Value := 'application/json';
end;

function WeightOrDefault(AValue, ADefault: Double): Double;
begin
  { Negative = "not set" (use the documented default); 0 is a real weight. }
  if AValue < 0 then Exit(ADefault);
  if AValue > 1 then RaiseUDAW(errInvalidArgument, SUBSYS, 'Reference weight must be between 0 and 1.');
  Result := AValue;
end;

function TLumaClient.RequestBody(const ARequest: TLumaRequest): string;
const
  ASPECTS: array[0..6] of string = ('1:1', '16:9', '9:16', '4:3', '3:4', '21:9', '9:21');
var
  caps: TLumaCapabilities;
  root, kf, ref, item: TJSONValue;
  u: string;
begin
  caps := LumaCapabilities(ARequest.Kind);
  if FApiKey = '' then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'Luma needs an API key.');
  if not OneOf(ARequest.Model, caps.Models) then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'Unsupported Luma model: ' + ARequest.Model);
  if (Trim(ARequest.Prompt) = '') and not ((ARequest.Kind = lmkVideo) and (ARequest.StartFrameUrl <> '')) then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'Enter a prompt (or a start frame for video).');
  if (ARequest.AspectRatio <> '') and not OneOf(ARequest.AspectRatio, ASPECTS) then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'Unsupported aspect ratio: ' + ARequest.AspectRatio);
  for u in [ARequest.StartFrameUrl, ARequest.EndFrameUrl, ARequest.ImageRefUrl,
    ARequest.StyleRefUrl, ARequest.CharacterRefUrl, ARequest.ModifyRefUrl] do
    if (u <> '') and (Pos('https://', LowerCase(u)) <> 1) then
      RaiseUDAW(errInvalidArgument, SUBSYS, 'Luma only accepts public HTTPS image URLs, not local files: ' + u);
  root := JSONObject;
  try
    root.AddPair('model', JSONString(ARequest.Model));
    if Trim(ARequest.Prompt) <> '' then root.AddPair('prompt', JSONString(ARequest.Prompt));
    if ARequest.AspectRatio <> '' then root.AddPair('aspect_ratio', JSONString(ARequest.AspectRatio));
    if ARequest.Kind = lmkVideo then
    begin
      root.AddPair('generation_type', JSONString('video'));
      if (ARequest.Resolution <> '') then
      begin
        if not OneOf(ARequest.Resolution, ['540p', '720p', '1080p', '4k']) then
          RaiseUDAW(errInvalidArgument, SUBSYS, 'Unsupported resolution: ' + ARequest.Resolution);
        root.AddPair('resolution', JSONString(ARequest.Resolution));
      end;
      if (ARequest.Duration <> '') then
      begin
        if not OneOf(ARequest.Duration, ['5s', '9s']) then
          RaiseUDAW(errInvalidArgument, SUBSYS, 'Unsupported duration: ' + ARequest.Duration);
        root.AddPair('duration', JSONString(ARequest.Duration));
      end;
      if ARequest.Loop then root.AddPair('loop', JSONBool(True));
      if Length(ARequest.Concepts) > 0 then
      begin
        ref := JSONArray;
        for u in ARequest.Concepts do
        begin
          item := JSONObject; item.AddPair('key', JSONString(u));
          ref.AddItem(item);
        end;
        root.AddPair('concepts', ref);
      end;
      if (ARequest.StartFrameUrl <> '') or (ARequest.EndFrameUrl <> '') then
      begin
        kf := JSONObject;
        root.AddPair('keyframes', kf);
        if ARequest.StartFrameUrl <> '' then
        begin
          item := JSONObject; item.AddPair('type', JSONString('image'));
          item.AddPair('url', JSONString(ARequest.StartFrameUrl));
          kf.AddPair('frame0', item);
        end;
        if ARequest.EndFrameUrl <> '' then
        begin
          item := JSONObject; item.AddPair('type', JSONString('image'));
          item.AddPair('url', JSONString(ARequest.EndFrameUrl));
          kf.AddPair('frame1', item);
        end;
      end;
    end
    else
    begin
      root.AddPair('generation_type', JSONString('image'));
      if ARequest.ImageFormat <> '' then
      begin
        if not OneOf(ARequest.ImageFormat, ['jpg', 'png']) then
          RaiseUDAW(errInvalidArgument, SUBSYS, 'Unsupported image format: ' + ARequest.ImageFormat);
        root.AddPair('format', JSONString(ARequest.ImageFormat));
      end;
      if ARequest.StyleRefUrl <> '' then
      begin
        ref := JSONArray;
        item := JSONObject; item.AddPair('url', JSONString(ARequest.StyleRefUrl));
        item.AddPair('weight', JSONNumber(WeightOrDefault(ARequest.StyleRefWeight, 0.8)));
        ref.AddItem(item);
        root.AddPair('style_ref', ref);
      end;
      if ARequest.ImageRefUrl <> '' then
      begin
        ref := JSONArray;
        item := JSONObject; item.AddPair('url', JSONString(ARequest.ImageRefUrl));
        item.AddPair('weight', JSONNumber(WeightOrDefault(ARequest.ImageRefWeight, 0.85)));
        ref.AddItem(item);
        root.AddPair('image_ref', ref);
      end;
      if ARequest.ModifyRefUrl <> '' then
      begin
        item := JSONObject; item.AddPair('url', JSONString(ARequest.ModifyRefUrl));
        item.AddPair('weight', JSONNumber(WeightOrDefault(ARequest.ModifyRefWeight, 1.0)));
        root.AddPair('modify_image_ref', item);
      end;
      if ARequest.CharacterRefUrl <> '' then
      begin
        ref := JSONArray; ref.AddItem(JSONString(ARequest.CharacterRefUrl));
        item := JSONObject; item.AddPair('images', ref);
        kf := JSONObject; kf.AddPair('identity0', item);
        root.AddPair('character_ref', kf);
      end;
    end;
    Result := root.ToJSONString;
  finally
    root.Free;
  end;
end;

function TLumaClient.ParseGeneration(const ABody: string): TLumaGeneration;
var
  v, a: TJSONValue;
begin
  Result := Default(TLumaGeneration);
  v := Parse(ABody);
  try
    if v.HasName('detail') and not v.HasName('id') then
      RaiseUDAWFmt(errNetwork, SUBSYS, 'Luma rejected the request: %s', [v.ByName('detail').ToJSONString]);
    if not v.HasName('id') then RaiseUDAW(errParse, SUBSYS, 'Luma response has no generation id.');
    Result.Id := v.ByName('id').AsString;
    if v.HasName('state') then
    begin
      Result.StateText := v.ByName('state').AsString;
      Result.State := LumaStateFromText(Result.StateText);
    end;
    if v.HasName('failure_reason') and (v.ByName('failure_reason').Kind <> jkNull) then
      Result.FailureReason := v.ByName('failure_reason').AsString;
    if v.HasName('assets') and (v.ByName('assets').Kind = jkObject) then
    begin
      a := v.ByName('assets');
      if a.HasName('video') and (a.ByName('video').Kind <> jkNull) then Result.VideoUrl := a.ByName('video').AsString;
      if a.HasName('image') and (a.ByName('image').Kind <> jkNull) then Result.ImageUrl := a.ByName('image').AsString;
    end;
  finally
    v.Free;
  end;
end;

function TLumaClient.Submit(const ARequest: TLumaRequest): TLumaGeneration;
var
  path: string;
  resp: TAIHttpResponse;
begin
  if ARequest.Kind = lmkVideo then path := '/generations/video' else path := '/generations/image';
  { Paid request: single attempt, never retried. }
  resp := FHttp.Post(LUMA_BASE_URL + path, Headers, RequestBody(ARequest));
  if (resp.StatusCode < 200) or (resp.StatusCode >= 300) then
    RaiseUDAWFmt(errNetwork, SUBSYS, 'Luma generate HTTP %d. Not retried; check your Luma dashboard before resubmitting.', [resp.StatusCode]);
  Result := ParseGeneration(resp.Body);
end;

function TLumaClient.Poll(const AId: string): TLumaGeneration;
var
  resp: TAIHttpResponse;
  i: Integer;
begin
  if Trim(AId) = '' then RaiseUDAW(errInvalidArgument, SUBSYS, 'Empty generation id.');
  for i := 1 to Length(AId) do
    if not CharInSet(AId[i], ['0'..'9', 'a'..'f', 'A'..'F', '-']) then
      RaiseUDAW(errInvalidArgument, SUBSYS, 'Malformed generation id.');
  resp := FHttp.Get(LUMA_BASE_URL + '/generations/' + AId, Headers);
  if (resp.StatusCode < 200) or (resp.StatusCode >= 300) then
    RaiseUDAWFmt(errNetwork, SUBSYS, 'Luma poll HTTP %d.', [resp.StatusCode]);
  Result := ParseGeneration(resp.Body);
end;

function TLumaClient.WaitForCompletion(const AId: string; ATimeoutMs, APollIntervalMs: Integer): TLumaGeneration;
var
  started: UInt64;
  interval: Integer;
begin
  if ATimeoutMs <= 0 then RaiseUDAW(errInvalidArgument, SUBSYS, 'Timeout must be positive.');
  interval := APollIntervalMs;
  if interval < 500 then interval := 500;
  started := TThread.GetTickCount64;
  repeat
    Result := Poll(AId);
    if Assigned(FOnPoll) then FOnPoll(Result);
    if Result.State in [lsCompleted, lsFailed] then Exit;
    if TThread.GetTickCount64 - started >= UInt64(ATimeoutMs) then
      RaiseUDAW(errTimeout, SUBSYS, 'Luma generation timed out. Check your Luma dashboard before submitting another paid request.');
    Sleep(interval);
  until False;
end;

function TLumaClient.GetCreditsCents: Double;
var
  resp: TAIHttpResponse;
  v: TJSONValue;
begin
  resp := FHttp.Get(LUMA_BASE_URL + '/credits', Headers);
  if resp.StatusCode = 401 then
    RaiseUDAW(errNetwork, SUBSYS, 'Luma rejected the API key (401).');
  if (resp.StatusCode < 200) or (resp.StatusCode >= 300) then
    RaiseUDAWFmt(errNetwork, SUBSYS, 'Luma credits HTTP %d.', [resp.StatusCode]);
  v := Parse(resp.Body);
  try
    if not v.HasName('credit_balance') then RaiseUDAW(errParse, SUBSYS, 'No credit_balance in response.');
    Result := v.ByName('credit_balance').AsNumber;
  finally
    v.Free;
  end;
end;

function TLumaClient.GetConcepts: TArray<string>;
var
  resp: TAIHttpResponse;
  v: TJSONValue;
  i: Integer;
begin
  resp := FHttp.Get(LUMA_BASE_URL + '/generations/concepts/list', Headers);
  if (resp.StatusCode < 200) or (resp.StatusCode >= 300) then
    RaiseUDAWFmt(errNetwork, SUBSYS, 'Luma concepts HTTP %d.', [resp.StatusCode]);
  v := Parse(resp.Body);
  try
    if v.Kind <> jkArray then RaiseUDAW(errParse, SUBSYS, 'Expected a concept list.');
    SetLength(Result, v.Count);
    for i := 0 to v.Count - 1 do Result[i] := v.Items[i].AsString;
  finally
    v.Free;
  end;
end;

procedure TLumaClient.Download(const AUrl, AOutFile: string);
var
  resp: TBytes;
  fs: TFileStream;
  status: Integer;
begin
  if Pos('https://', LowerCase(AUrl)) <> 1 then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'Refusing to download from a non-HTTPS URL.');
  resp := FHttp.GetBytes(AUrl, [], status);
  if (status < 200) or (status >= 300) or (Length(resp) = 0) then RaiseUDAW(errNetwork, SUBSYS, 'Luma asset download failed.');
  fs := TFileStream.Create(AOutFile, fmCreate);
  try
    fs.WriteBuffer(resp[0], Length(resp));
  finally
    fs.Free;
  end;
end;

constructor TLumaGenerationJob.Create(const AKey: string; const ARequest: TLumaRequest;
  const AOutputDir: string);
begin
  inherited Create('Luma generation');
  FRequest := ARequest;
  FOutputDir := Trim(AOutputDir);
  FClient := TLumaClient.Create(AKey);
  FClient.RequestBody(FRequest); // validate up front so bad input fails before queueing
  FClient.OnPoll := PollProgress;
end;

destructor TLumaGenerationJob.Destroy;
begin
  FClient.Free;
  inherited Destroy;
end;

function TLumaGenerationJob.DurationSeconds: Double;
begin
  if FRequest.Kind <> lmkVideo then Exit(0);
  if FRequest.Duration = '9s' then Result := 9 else Result := 5;
end;

function TLumaGenerationJob.IsVideo: Boolean;
begin
  Result := FRequest.Kind = lmkVideo;
end;

procedure TLumaGenerationJob.PollProgress(const AGen: TLumaGeneration);
begin
  ThrowIfCancelled;
  SetProgress(0, 'Luma: ' + AGen.StateText); // provider gives no percentage
end;

function TLumaGenerationJob.Execute: Boolean;
var
  gen: TLumaGeneration;
  url, ext, dir, base: string;
  n: Integer;
begin
  ThrowIfCancelled;
  SetProgress(0, 'Submitting to Luma');
  gen := FClient.Submit(FRequest);
  ThrowIfCancelled;
  if not (gen.State in [lsCompleted, lsFailed]) then
    gen := FClient.WaitForCompletion(gen.Id, 900000, 3000);
  ThrowIfCancelled;
  if gen.State = lsFailed then
    RaiseUDAW(errNetwork, SUBSYS, 'Luma generation failed: ' + gen.FailureReason);
  if FRequest.Kind = lmkVideo then
  begin
    url := gen.VideoUrl; ext := '.mp4';
  end
  else
  begin
    url := gen.ImageUrl;
    if FRequest.ImageFormat = 'png' then ext := '.png' else ext := '.jpg';
  end;
  if url = '' then RaiseUDAW(errParse, SUBSYS, 'Completed Luma generation has no media URL.');
  dir := FOutputDir;
  if dir = '' then dir := IncludeTrailingPathDelimiter(GetCurrentDir) + 'Luma';
  dir := IncludeTrailingPathDelimiter(dir) + 'Luma';
  ForceDirectories(dir);
  base := IncludeTrailingPathDelimiter(dir) + 'luma_' + Copy(gen.Id, 1, 8);
  FOutputPath := base + ext;
  n := 1;
  while FileExists(FOutputPath) do
  begin
    Inc(n);
    FOutputPath := Format('%s_%d%s', [base, n, ext]);
  end;
  SetProgress(0.9, 'Downloading result');
  FClient.Download(url, FOutputPath);
  ThrowIfCancelled;
  SetProgress(1, 'Luma result saved');
  Result := True;
end;

end.
