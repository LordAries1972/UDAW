unit UDAW.AI.Composer;
{$I udaw.inc}

{ AI Composition, Phase 3 - AI Provider Layer (docs/AIPlan.md section 17
  "PHASE 3 - AI PROVIDER LAYER", and section 2A's IAIProvider method list:
  Initialize/Authenticate/SubmitCompositionRequest/SubmitRevisionRequest/
  GenerateLyrics/AnalyzeLyrics/AnalyzeArrangement/CancelRequest/
  GetRequestStatus/GetLastError).

  ICompositionProvider sits ABOVE the existing chat-shaped IAIProvider
  (UDAW.AI.Types, Phase 20) rather than adding these methods to it in place:
  IAIProvider already has three concrete, tested implementations (OpenAI/
  Claude/DeepSeek, Phases 21-23) that only implement the five chat-oriented
  methods, and changing that interface would break all three. Wrapping any
  one of them behind TCompositionProvider gets every AIPlan.md Phase 3
  requirement (structured JSON, retry, cancellation, request-status polling,
  redacted logging) without touching the provider units at all.

    * secure credentials - already solved (UDAW.AI.Credentials, an OS-backed
      ISecureStore); CreateCompositionProvider reads the key from there.
    * request/cancellation handling - a monotonic request-id + TAICancelToken
      per call, polled from GetRequestStatus/CancelRequest so a UI thread can
      track or abort work a background thread started.
    * structured responses - every Submit*/Generate* call instructs the
      provider to reply with ONE JSON object matching AIPlan.md section 5's
      shape and parses it with UDAW.AI.JSON; a parse failure or a
      TSongSpecValidator error is fed back to the provider as a corrective
      follow-up and retried, up to AMaxRetries times.
    * retry and error reporting - CallWithRetry retries a transport failure
      (errNetwork/errTimeout) with a short backoff; GetLastError exposes the
      final failure reason.
    * log usage without exposing private content - every HTTP call already
      goes through UDAW.AI.HTTP, which logs via UDAW.AI.SecureLog (method +
      URL + body LENGTH only); this unit adds no logging of its own that
      could leak a prompt, a response or a key. }

interface

uses
  SysUtils, Math, Generics.Collections, SyncObjs,
  UDAW.Errors,
  UDAW.AI.Types, UDAW.AI.JSON, UDAW.AI.HTTP, UDAW.AI.SecureLog,
  UDAW.AI.RateLimiter, UDAW.AI.Credentials, UDAW.AI.Providers,
  UDAW.Browser.Catalogue,
  UDAW.Composer.SongSpec, UDAW.Composer.Lyrics, UDAW.Composer.Validation;

const
  COMPOSER_AI_SUBSYS = 'AI.Composer';
  COMPOSITION_DEFAULT_MAX_RETRIES = 2;

type
  TCompositionRequestKind = (
    crkComposition, crkRevision, crkLyrics, crkAnalyzeLyrics, crkAnalyzeArrangement);

  TCompositionRequestState = (crsIdle, crsRunning, crsSucceeded, crsFailed, crsCancelled);

  TCompositionRequestStatus = record
    Id: Int64;
    Kind: TCompositionRequestKind;
    State: TCompositionRequestState;
    Attempts: Integer;
    ErrorMessage: string;
  end;

  ICompositionProvider = interface
    ['{7B9E2F3A-1D4C-4A8E-9B2D-6C3F5E7A9D02}']
    procedure Initialize;
    function Authenticate: Boolean;

    { Every call below is synchronous (mirrors IAIProvider.SendMessage) but
      is tracked by request id, so a caller that runs it on a worker thread
      can still CancelRequest / GetRequestStatus it from the UI thread. The
      returned Int64 is that request id. }
    function SubmitCompositionRequest(const AUserRequest: string;
      ACatalogue: TInstrumentCatalogue; out ASpec: TSongSpec;
      out ALyrics: TLyricDocument): Int64;
    { AScopeTrackIds/AScopeSectionIds implement AIPlan.md section 17 PHASE 8
      "Modify selected tracks or regions": when either array is non-empty,
      only sections/tracks whose Id appears in the matching array (plus
      anything the AI itself only ever touches) may change - every other
      section/track, and any section/track with Locked = True regardless of
      scope ("Preserve locked content"), is restored to AExistingSpec's copy
      after the AI replies, whatever the AI returned for it. Pass nil for
      both to revise the whole (unlocked) specification. }
    function SubmitRevisionRequest(AExistingSpec: TSongSpec; AExistingLyrics: TLyricDocument;
      const AInstruction: string; out ARevisedSpec: TSongSpec;
      out ARevisedLyrics: TLyricDocument; const AScopeTrackIds: TArray<string>;
      const AScopeSectionIds: TArray<string>): Int64;
    function GenerateLyrics(ASpec: TSongSpec; const ASubject, ALanguage: string;
      out ALyrics: TLyricDocument): Int64;
    function AnalyzeLyrics(ASpec: TSongSpec; ALyrics: TLyricDocument; out AReport: string): Int64;
    function AnalyzeArrangement(ASpec: TSongSpec; out AReport: string): Int64;

    procedure CancelRequest(ARequestId: Int64);
    function GetRequestStatus(ARequestId: Int64): TCompositionRequestStatus;
    function GetLastError: string;

    function ProviderId: string;
  end;

  TCompositionProvider = class(TInterfacedObject, ICompositionProvider)
  private
    FInner: IAIProvider;
    FModel: string;
    FMaxRetries: Integer;
    FLock: TCriticalSection;
    FNextId: Int64;
    FStatuses: TDictionary<Int64, TCompositionRequestStatus>;
    FCancelTokens: TObjectDictionary<Int64, TAICancelToken>;
    FLastError: string;
    FRateLimiter: TAIRateLimiter;

    function NewRequest(AKind: TCompositionRequestKind): Int64;
    procedure SetStatus(AId: Int64; AState: TCompositionRequestState; const AErr: string = '');
    function TokenFor(AId: Int64): TAICancelToken;
    procedure ForgetToken(AId: Int64);

    { Sends one prompt, retrying transport failures up to FMaxRetries times.
      Returns the raw reply text, or '' with GetLastError set on final
      failure / cancellation. }
    function CallWithRetry(AId: Int64; const ASystemPrompt: string;
      AUserPrompt: string; out AReplyText: string): Boolean;

    { Parses AText as the AIPlan.md section 5 JSON shape into ASpec/ALyrics.
      Runs TSongSpecValidator afterwards; a schema/parse failure is reported
      through AParseError (never raises) so the caller can retry with a
      corrective follow-up prompt. }
    function ParseSongSpecJSON(const AText: string; out ASpec: TSongSpec;
      out ALyrics: TLyricDocument; out AParseError: string): Boolean;
    function ParseLyricsOnlyJSON(const AText: string; out ALyrics: TLyricDocument;
      out AParseError: string): Boolean;

    function RunStructuredRequest(AId: Int64; const ASystemPrompt, AUserPrompt: string;
      out ASpec: TSongSpec; out ALyrics: TLyricDocument): Boolean;
  public
    constructor Create(AInner: IAIProvider; const AModel: string = '';
      AMaxRetries: Integer = COMPOSITION_DEFAULT_MAX_RETRIES);
    destructor Destroy; override;

    procedure Initialize;
    function Authenticate: Boolean;

    function SubmitCompositionRequest(const AUserRequest: string;
      ACatalogue: TInstrumentCatalogue; out ASpec: TSongSpec;
      out ALyrics: TLyricDocument): Int64;
    function SubmitRevisionRequest(AExistingSpec: TSongSpec; AExistingLyrics: TLyricDocument;
      const AInstruction: string; out ARevisedSpec: TSongSpec;
      out ARevisedLyrics: TLyricDocument; const AScopeTrackIds: TArray<string>;
      const AScopeSectionIds: TArray<string>): Int64;
    function GenerateLyrics(ASpec: TSongSpec; const ASubject, ALanguage: string;
      out ALyrics: TLyricDocument): Int64;
    function AnalyzeLyrics(ASpec: TSongSpec; ALyrics: TLyricDocument; out AReport: string): Int64;
    function AnalyzeArrangement(ASpec: TSongSpec; out AReport: string): Int64;

    procedure CancelRequest(ARequestId: Int64);
    function GetRequestStatus(ARequestId: Int64): TCompositionRequestStatus;
    function GetLastError: string;

    function ProviderId: string;
  end;

{ Restores, in-place on ARevisedSpec, every section/track that is either
  Locked on AExistingSpec or (when the matching scope array is non-empty)
  outside that scope - AIPlan.md section 17 PHASE 8 "Preserve locked
  content" / "Modify selected tracks or regions". Sections/tracks the AI
  added that were not in AExistingSpec are left alone (out-of-scope only
  constrains EXISTING content). Exported so a caller applying a revision it
  built itself (not through TCompositionProvider) can enforce the same
  guarantee. }
procedure MergeLockedAndOutOfScope(AExistingSpec, ARevisedSpec: TSongSpec;
  const AScopeTrackIds, AScopeSectionIds: TArray<string>);

{ Looks up the stored credential for AProviderId (UDAW.AI.Credentials),
  builds the concrete chat provider (UDAW.AI.Providers.CreateAIProvider) and
  wraps it. Returns nil if the provider id is unknown or no key is stored. }
function CreateCompositionProvider(const AProviderId: string;
  const AModel: string = ''): ICompositionProvider;

function CompositionRequestKindId(AKind: TCompositionRequestKind): string;
function CompositionRequestStateId(AState: TCompositionRequestState): string;

implementation

const
  RETRY_BACKOFF_BASE_MS = 400;

function CompositionRequestKindId(AKind: TCompositionRequestKind): string;
begin
  case AKind of
    crkComposition:        Result := 'composition';
    crkRevision:            Result := 'revision';
    crkLyrics:               Result := 'lyrics';
    crkAnalyzeLyrics:        Result := 'analyze_lyrics';
    crkAnalyzeArrangement:  Result := 'analyze_arrangement';
  else
    Result := 'unknown';
  end;
end;

function CompositionRequestStateId(AState: TCompositionRequestState): string;
begin
  case AState of
    crsIdle:      Result := 'idle';
    crsRunning:    Result := 'running';
    crsSucceeded:  Result := 'succeeded';
    crsFailed:      Result := 'failed';
    crsCancelled:  Result := 'cancelled';
  else
    Result := 'unknown';
  end;
end;

{ ---------------- JSON helpers ---------------- }

function JStr(AObj: TJSONValue; const AName: string; const ADefault: string = ''): string;
var
  v: TJSONValue;
begin
  Result := ADefault;
  if AObj = nil then Exit;
  v := AObj.ByName(AName);
  if (v <> nil) and (v.Kind = jkString) then Result := v.AsString;
end;

function JNum(AObj: TJSONValue; const AName: string; ADefault: Double = 0): Double;
var
  v: TJSONValue;
begin
  Result := ADefault;
  if AObj = nil then Exit;
  v := AObj.ByName(AName);
  if (v <> nil) and (v.Kind = jkNumber) then Result := v.AsNumber;
end;

function JBool(AObj: TJSONValue; const AName: string; ADefault: Boolean = False): Boolean;
var
  v: TJSONValue;
begin
  Result := ADefault;
  if AObj = nil then Exit;
  v := AObj.ByName(AName);
  if (v <> nil) and (v.Kind = jkBool) then Result := v.AsBool;
end;

procedure SplitTimeSig(const AText: string; out ANum, ADen: Integer);
var
  p: Integer;
begin
  ANum := 4; ADen := 4;
  p := Pos('/', AText);
  if p > 0 then
  begin
    ANum := StrToIntDef(Copy(AText, 1, p - 1), 4);
    ADen := StrToIntDef(Copy(AText, p + 1, MaxInt), 4);
  end;
end;

function BuildSongSpecSchemaText: string;
begin
  { A terse restatement of AIPlan.md section 5's JSON shape - short enough to
    keep in every prompt without ballooning token usage. }
  Result :=
    '{"project":{"title":string,"instrumental":bool,"tempo":number,"key":string,' +
    '"scale":string,"timeSignature":"N/D","durationBars":integer},' +
    '"sections":[{"id":string,"name":string,"startBar":integer,"lengthBars":integer,"energy":0..1}],' +
    '"tracks":[{"id":string,"name":string,"type":"midi|audio|bus","role":string,' +
    '"requestedTags":[string],"preferredInstrumentId":string,"fallbackCategory":string,"midiChannel":integer,' +
    '"requireMidi":bool}],' +
    '"harmony":{"chordProgressions":[{"sectionId":string,"chords":[string],"barsPerChord":integer}]},' +
    '"lyrics":{"language":string,"sections":[{"sectionId":string,' +
    '"lines":[{"text":string,"startBar":integer,"durationBars":integer}]}]}}';
end;

function ArrayContainsId(const AArray: TArray<string>; const AId: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(AArray) do
    if SameText(AArray[i], AId) then Exit(True);
end;

procedure MergeLockedAndOutOfScope(AExistingSpec, ARevisedSpec: TSongSpec;
  const AScopeTrackIds, AScopeSectionIds: TArray<string>);
var
  i: Integer;
  oldSec, newSec: TSongSection;
  oldTrk, newTrk: TSongTrackSpec;
  restrictSections, restrictTracks: Boolean;
begin
  if (AExistingSpec = nil) or (ARevisedSpec = nil) then Exit;
  restrictSections := Length(AScopeSectionIds) > 0;
  restrictTracks := Length(AScopeTrackIds) > 0;

  for i := 0 to AExistingSpec.Sections.Count - 1 do
  begin
    oldSec := AExistingSpec.Sections[i];
    if oldSec.Locked or (restrictSections and not ArrayContainsId(AScopeSectionIds, oldSec.Id)) then
    begin
      newSec := ARevisedSpec.SectionById(oldSec.Id);
      if newSec <> nil then
      begin
        newSec.Name := oldSec.Name;
        newSec.StartBar := oldSec.StartBar;
        newSec.LengthBars := oldSec.LengthBars;
        newSec.Energy := oldSec.Energy;
        newSec.Locked := oldSec.Locked;
      end
      else
        ARevisedSpec.AddSection(oldSec.Clone);
    end;
  end;

  for i := 0 to AExistingSpec.Tracks.Count - 1 do
  begin
    oldTrk := AExistingSpec.Tracks[i];
    if oldTrk.Locked or (restrictTracks and not ArrayContainsId(AScopeTrackIds, oldTrk.Id)) then
    begin
      newTrk := ARevisedSpec.TrackById(oldTrk.Id);
      if newTrk <> nil then
      begin
        newTrk.Name := oldTrk.Name;
        newTrk.Kind := oldTrk.Kind;
        newTrk.Role := oldTrk.Role;
        newTrk.RequestedTags := Copy(oldTrk.RequestedTags);
        newTrk.PreferredInstrumentId := oldTrk.PreferredInstrumentId;
        newTrk.FallbackCategory := oldTrk.FallbackCategory;
        newTrk.MidiChannel := oldTrk.MidiChannel;
        newTrk.Locked := oldTrk.Locked;
      end
      else
        ARevisedSpec.AddTrack(oldTrk.Clone);
    end;
  end;
end;

{ ---------------- factory ---------------- }

function CreateCompositionProvider(const AProviderId: string;
  const AModel: string): ICompositionProvider;
var
  key: string;
  inner: IAIProvider;
begin
  Result := nil;
  if not GetAIApiKey(AProviderId, key) then Exit;
  if Trim(key) = '' then Exit;
  inner := CreateAIProvider(AProviderId, key);
  if inner = nil then Exit;
  Result := TCompositionProvider.Create(inner, AModel);
end;

{ ================= TCompositionProvider ================= }

constructor TCompositionProvider.Create(AInner: IAIProvider; const AModel: string;
  AMaxRetries: Integer);
begin
  inherited Create;
  if AInner = nil then
    RaiseUDAW(errInvalidArgument, COMPOSER_AI_SUBSYS, 'a composition provider needs an inner IAIProvider');
  FInner := AInner;
  FModel := AModel;
  FMaxRetries := Max(0, AMaxRetries);
  FLock := TCriticalSection.Create;
  FStatuses := TDictionary<Int64, TCompositionRequestStatus>.Create;
  FCancelTokens := TObjectDictionary<Int64, TAICancelToken>.Create([doOwnsValues]);
  FRateLimiter := TAIRateLimiter.Create;
  FNextId := 0;
end;

destructor TCompositionProvider.Destroy;
begin
  FRateLimiter.Free;
  FCancelTokens.Free;
  FStatuses.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TCompositionProvider.Initialize;
begin
  { The inner IAIProvider (OpenAI/Claude/DeepSeek) is already fully
    constructed with its API key by CreateCompositionProvider / the caller -
    there is no separate connect step, matching how UDAW.AI.HTTP is a
    stateless per-call client. Kept as a no-op entry point so callers that
    follow AIPlan.md section 2A's Initialize/Authenticate/Submit... sequence
    literally have something to call first. }
end;

function TCompositionProvider.Authenticate: Boolean;
var
  models: TArray<string>;
begin
  { No dedicated auth-check endpoint is assumed for every provider - probing
    ListModels (already implemented by all three Phase 21-23 providers, and
    documented to fail soft rather than raise) is a real, low-cost way to
    confirm the stored key is accepted. }
  try
    models := FInner.ListModels;
    Result := Length(models) > 0;
    if not Result then
      FLastError := 'authentication check failed: provider returned no models';
  except
    on E: Exception do
    begin
      FLastError := 'authentication check failed: ' + E.Message;
      Result := False;
    end;
  end;
end;

function TCompositionProvider.ProviderId: string;
begin
  Result := FInner.ProviderId;
end;

function TCompositionProvider.NewRequest(AKind: TCompositionRequestKind): Int64;
var
  st: TCompositionRequestStatus;
begin
  FLock.Enter;
  try
    Inc(FNextId);
    Result := FNextId;
    st.Id := Result;
    st.Kind := AKind;
    st.State := crsRunning;
    st.Attempts := 0;
    st.ErrorMessage := '';
    FStatuses.AddOrSetValue(Result, st);
    FCancelTokens.AddOrSetValue(Result, TAICancelToken.Create);
  finally
    FLock.Leave;
  end;
end;

procedure TCompositionProvider.SetStatus(AId: Int64; AState: TCompositionRequestState;
  const AErr: string);
var
  st: TCompositionRequestStatus;
begin
  FLock.Enter;
  try
    if not FStatuses.TryGetValue(AId, st) then Exit;
    st.State := AState;
    if AErr <> '' then
    begin
      st.ErrorMessage := AErr;
      FLastError := AErr;
    end;
    FStatuses[AId] := st;
  finally
    FLock.Leave;
  end;
  { A terminal request has nothing left to cancel - drop its token so
    FCancelTokens doesn't grow for the life of the provider. }
  if AState in [crsSucceeded, crsFailed, crsCancelled] then
    ForgetToken(AId);
end;

function TCompositionProvider.TokenFor(AId: Int64): TAICancelToken;
begin
  FLock.Enter;
  try
    if not FCancelTokens.TryGetValue(AId, Result) then
      Result := nil;
  finally
    FLock.Leave;
  end;
end;

procedure TCompositionProvider.ForgetToken(AId: Int64);
begin
  FLock.Enter;
  try
    FCancelTokens.Remove(AId);
  finally
    FLock.Leave;
  end;
end;

procedure TCompositionProvider.CancelRequest(ARequestId: Int64);
var
  tok: TAICancelToken;
begin
  tok := TokenFor(ARequestId);
  if tok <> nil then
    tok.Cancel;
  SetStatus(ARequestId, crsCancelled);
end;

function TCompositionProvider.GetRequestStatus(ARequestId: Int64): TCompositionRequestStatus;
begin
  FLock.Enter;
  try
    if not FStatuses.TryGetValue(ARequestId, Result) then
    begin
      Result.Id := ARequestId;
      Result.Kind := crkComposition;
      Result.State := crsIdle;
      Result.Attempts := 0;
      Result.ErrorMessage := 'unknown request id';
    end;
  finally
    FLock.Leave;
  end;
end;

function TCompositionProvider.GetLastError: string;
begin
  FLock.Enter;
  try
    Result := FLastError;
  finally
    FLock.Leave;
  end;
end;

function TCompositionProvider.CallWithRetry(AId: Int64; const ASystemPrompt: string;
  AUserPrompt: string; out AReplyText: string): Boolean;
var
  req: TAIRequest;
  resp: TAIResponse;
  attempt: Integer;
  tok: TAICancelToken;
  waitMs: Integer;
  st: TCompositionRequestStatus;
begin
  AReplyText := '';
  Result := False;
  tok := TokenFor(AId);

  for attempt := 1 to FMaxRetries + 1 do
  begin
    if (tok <> nil) and tok.IsCancelled then
    begin
      SetStatus(AId, crsCancelled);
      Exit(False);
    end;

    FLock.Enter;
    try
      if FStatuses.TryGetValue(AId, st) then
      begin
        st.Attempts := attempt;
        FStatuses[AId] := st;
      end;
    finally
      FLock.Leave;
    end;

    if not FRateLimiter.TryAcquire(Length(ASystemPrompt) + Length(AUserPrompt), waitMs) then
      Sleep(Min(waitMs, 5000));

    req.Model := FModel;
    SetLength(req.Messages, 2);
    req.Messages[0].Role := arSystem;
    req.Messages[0].Content := ASystemPrompt;
    req.Messages[1].Role := arUser;
    req.Messages[1].Content := AUserPrompt;
    req.Temperature := 0.7;
    req.MaxTokens := 4096;
    req.Stream := False;

    try
      resp := FInner.SendMessage(req, tok);
      FRateLimiter.RecordActualUsage(resp.PromptTokens + resp.CompletionTokens);
      AReplyText := resp.Content;
      Exit(True);
    except
      on E: EUDAWError do
      begin
        AISecureLog.Warn(COMPOSER_AI_SUBSYS, Format(
          'composition request %d attempt %d/%d failed (%s): %s',
          [AId, attempt, FMaxRetries + 1, ErrorCodeName(E.Code), E.Message]));
        if E.Code = errCancelled then
        begin
          SetStatus(AId, crsCancelled);
          Exit(False);
        end;
        if attempt > FMaxRetries then
        begin
          SetStatus(AId, crsFailed, E.Message);
          Exit(False);
        end;
        Sleep(RETRY_BACKOFF_BASE_MS * attempt);
      end;
      on E: Exception do
      begin
        if attempt > FMaxRetries then
        begin
          SetStatus(AId, crsFailed, E.Message);
          Exit(False);
        end;
        Sleep(RETRY_BACKOFF_BASE_MS * attempt);
      end;
    end;
  end;
end;

function TCompositionProvider.ParseSongSpecJSON(const AText: string; out ASpec: TSongSpec;
  out ALyrics: TLyricDocument; out AParseError: string): Boolean;
var
  root, projectObj, arr, obj, sub, harmObj, progArr, lyrObj, lsecArr, lsecObj, lineArr, lineObj: TJSONValue;
  i, j: Integer;
  sec: TSongSection;
  trk: TSongTrackSpec;
  prog: TChordProgressionEntry;
  lsec: TLyricSection;
  num, den: Integer;
  issues: TValidationIssues;
  s: string;
  tagArr: TArray<string>;
begin
  ASpec := nil;
  ALyrics := nil;
  AParseError := '';
  try
    root := Parse(Trim(AText));
  except
    on E: EUDAWError do
    begin
      AParseError := 'invalid JSON: ' + E.Message;
      Exit(False);
    end;
  end;

  try
    if (root = nil) or (root.Kind <> jkObject) then
    begin
      AParseError := 'expected a top-level JSON object';
      Exit(False);
    end;

    ASpec := TSongSpec.Create;
    try
      projectObj := root.ByName('project');
      ASpec.Meta.Title := JStr(projectObj, 'title', 'Untitled Song');
      ASpec.Meta.Instrumental := JBool(projectObj, 'instrumental', False);
      ASpec.Meta.Tempo := JNum(projectObj, 'tempo', 120);
      ASpec.Meta.Key := JStr(projectObj, 'key', 'C');
      ASpec.Meta.Scale := JStr(projectObj, 'scale', 'major');
      SplitTimeSig(JStr(projectObj, 'timeSignature', '4/4'), num, den);
      ASpec.Meta.TimeSigNum := num;
      ASpec.Meta.TimeSigDen := den;
      ASpec.Meta.DurationBars := Trunc(JNum(projectObj, 'durationBars', 32));

      arr := root.ByName('sections');
      if arr <> nil then
        for i := 0 to arr.Count - 1 do
        begin
          obj := arr.Items[i];
          sec := TSongSection.Create(JStr(obj, 'id'), JStr(obj, 'name'),
            Trunc(JNum(obj, 'startBar', 1)), Trunc(JNum(obj, 'lengthBars', 4)),
            JNum(obj, 'energy', 0.5));
          ASpec.AddSection(sec);
        end;

      arr := root.ByName('tracks');
      if arr <> nil then
        for i := 0 to arr.Count - 1 do
        begin
          obj := arr.Items[i];
          trk := TSongTrackSpec.Create(JStr(obj, 'id'), JStr(obj, 'name'), stkMidi, JStr(obj, 'role'));
          s := LowerCase(JStr(obj, 'type', 'midi'));
          if s = 'audio' then trk.Kind := stkAudio
          else if s = 'bus' then trk.Kind := stkBus
          else trk.Kind := stkMidi;
          sub := obj.ByName('requestedTags');
          if sub <> nil then
          begin
            SetLength(tagArr, sub.Count);
            for j := 0 to sub.Count - 1 do
              tagArr[j] := sub.Items[j].AsString;
            trk.RequestedTags := tagArr;
          end;
          trk.PreferredInstrumentId := JStr(obj, 'preferredInstrumentId');
          trk.FallbackCategory := JStr(obj, 'fallbackCategory');
          trk.MidiChannel := Trunc(JNum(obj, 'midiChannel', -1));
          trk.RequireMidi := JBool(obj, 'requireMidi', False);
          ASpec.AddTrack(trk);
        end;

      harmObj := root.ByName('harmony');
      if harmObj <> nil then
      begin
        progArr := harmObj.ByName('chordProgressions');
        if progArr <> nil then
          for i := 0 to progArr.Count - 1 do
          begin
            obj := progArr.Items[i];
            prog := TChordProgressionEntry.Create(JStr(obj, 'sectionId'), Trunc(JNum(obj, 'barsPerChord', 1)));
            sub := obj.ByName('chords');
            if sub <> nil then
            begin
              SetLength(tagArr, sub.Count);
              for j := 0 to sub.Count - 1 do
                tagArr[j] := sub.Items[j].AsString;
              prog.Chords := tagArr;
            end;
            ASpec.AddChordProgression(prog);
          end;
      end;

      ALyrics := TLyricDocument.Create;
      lyrObj := root.ByName('lyrics');
      if lyrObj <> nil then
      begin
        ALyrics.Language := JStr(lyrObj, 'language', 'English');
        lsecArr := lyrObj.ByName('sections');
        if lsecArr <> nil then
          for i := 0 to lsecArr.Count - 1 do
          begin
            lsecObj := lsecArr.Items[i];
            lsec := TLyricSection.Create(JStr(lsecObj, 'sectionId'));
            lineArr := lsecObj.ByName('lines');
            if lineArr <> nil then
              for j := 0 to lineArr.Count - 1 do
              begin
                lineObj := lineArr.Items[j];
                lsec.AddLine(TLyricLine.Create(JStr(lineObj, 'text'),
                  Trunc(JNum(lineObj, 'startBar', 1)), Trunc(JNum(lineObj, 'durationBars', 1))));
              end;
            ALyrics.AddSection(lsec);
          end;
      end;

      TSongSpecValidator.ApplyDefaults(ASpec);
      issues := TSongSpecValidator.Validate(ASpec, ALyrics);
      if TSongSpecValidator.HasErrors(issues) then
      begin
        s := '';
        for i := 0 to High(issues) do
          if issues[i].Severity = vsError then
            s := s + '- ' + issues[i].Message + #10;
        AParseError := 'song specification failed validation:'#10 + s;
        FreeAndNil(ASpec);
        FreeAndNil(ALyrics);
        Exit(False);
      end;

      Result := True;
    except
      on E: Exception do
      begin
        AParseError := 'could not build song specification from response: ' + E.Message;
        FreeAndNil(ASpec);
        FreeAndNil(ALyrics);
        Result := False;
      end;
    end;
  finally
    root.Free;
  end;
end;

function TCompositionProvider.ParseLyricsOnlyJSON(const AText: string; out ALyrics: TLyricDocument;
  out AParseError: string): Boolean;
var
  root, lsecArr, lsecObj, lineArr, lineObj: TJSONValue;
  i, j: Integer;
  lsec: TLyricSection;
begin
  ALyrics := nil;
  AParseError := '';
  try
    root := Parse(Trim(AText));
  except
    on E: EUDAWError do
    begin
      AParseError := 'invalid JSON: ' + E.Message;
      Exit(False);
    end;
  end;

  try
    if (root = nil) or (root.Kind <> jkObject) then
    begin
      AParseError := 'expected a top-level JSON object';
      Exit(False);
    end;
    ALyrics := TLyricDocument.Create;
    ALyrics.Language := JStr(root, 'language', 'English');
    lsecArr := root.ByName('sections');
    if lsecArr <> nil then
      for i := 0 to lsecArr.Count - 1 do
      begin
        lsecObj := lsecArr.Items[i];
        lsec := TLyricSection.Create(JStr(lsecObj, 'sectionId'));
        lineArr := lsecObj.ByName('lines');
        if lineArr <> nil then
          for j := 0 to lineArr.Count - 1 do
          begin
            lineObj := lineArr.Items[j];
            lsec.AddLine(TLyricLine.Create(JStr(lineObj, 'text'),
              Trunc(JNum(lineObj, 'startBar', 1)), Trunc(JNum(lineObj, 'durationBars', 1))));
          end;
        ALyrics.AddSection(lsec);
      end;
    Result := True;
  finally
    root.Free;
  end;
end;

function TCompositionProvider.RunStructuredRequest(AId: Int64; const ASystemPrompt,
  AUserPrompt: string; out ASpec: TSongSpec; out ALyrics: TLyricDocument): Boolean;
var
  attempt: Integer;
  userPrompt, reply, parseErr: string;
begin
  ASpec := nil;
  ALyrics := nil;
  Result := False;
  userPrompt := AUserPrompt;

  for attempt := 1 to FMaxRetries + 1 do
  begin
    if not CallWithRetry(AId, ASystemPrompt, userPrompt, reply) then
      Exit(False); // CallWithRetry already set status/last error

    if ParseSongSpecJSON(reply, ASpec, ALyrics, parseErr) then
    begin
      SetStatus(AId, crsSucceeded);
      Exit(True);
    end;

    AISecureLog.Warn(COMPOSER_AI_SUBSYS, Format(
      'composition request %d: structured-response check failed on attempt %d/%d',
      [AId, attempt, FMaxRetries + 1]));

    if attempt > FMaxRetries then
    begin
      SetStatus(AId, crsFailed, parseErr);
      Exit(False);
    end;

    { Ask again, this time telling the model exactly what was wrong -
      AIPlan.md section D: "Reject malformed responses... Produce clear
      validation messages" (here fed back to the AI, not just the user). }
    userPrompt := AUserPrompt + #10#10 +
      'Your previous reply could not be used:'#10 + parseErr + #10 +
      'Reply again with ONLY the corrected JSON object - no prose, no markdown fences.';
  end;
end;

function TCompositionProvider.SubmitCompositionRequest(const AUserRequest: string;
  ACatalogue: TInstrumentCatalogue; out ASpec: TSongSpec; out ALyrics: TLyricDocument): Int64;
var
  sysPrompt, userPrompt, catalogueJSON: string;
  catJSON: TJSONValue;
begin
  Result := NewRequest(crkComposition);

  catalogueJSON := '[]';
  if ACatalogue <> nil then
  begin
    catJSON := ACatalogue.SafeDescriptionsJSON;
    try
      catalogueJSON := catJSON.ToJSONString;
    finally
      catJSON.Free;
    end;
  end;

  sysPrompt :=
    'You are the composition engine of a digital audio workstation. ' +
    'Given a natural-language song request, reply with ONLY a single JSON object ' +
    '(no prose, no markdown fences) matching exactly this shape: ' + BuildSongSpecSchemaText + '. ' +
    'Only reference instrument ids/categories/tags that appear in the provided catalogue; ' +
    'never invent a file path (none is ever supplied to you). ' +
    'For every track, prefer a real sample or loop from the catalogue (kind "sample" or "loop") ' +
    'over generated performance data: set "type":"audio" and point preferredInstrumentId/' +
    'fallbackCategory/requestedTags at a matching sample or loop whenever one plausibly fits the ' +
    'part. Only set "type":"midi" (and, if you want the arrangement engine to skip sample/loop ' +
    'substitution entirely, "requireMidi":true) when the user explicitly asked for MIDI, a specific ' +
    'synth/instrument/patch, or a performance style (arpeggios, chord voicings, humanized playing) ' +
    'that only generated notes can express - never as a default choice. "type":"bus" needs neither.';

  userPrompt := Format(
    'Song request: %s'#10#10'Available instrument catalogue (JSON array of ' +
    '{id,name,category,kind,tags,roles,presets,available} - kind is "sample" or "loop" for real ' +
    'audio content, "instrument_vst"/"soundfont"/"drum_kit" for MIDI-driven sound sources): %s',
    [AUserRequest, catalogueJSON]);

  if RunStructuredRequest(Result, sysPrompt, userPrompt, ASpec, ALyrics) then
  begin
    ASpec.OriginalRequest := AUserRequest;
    ASpec.ProviderId := FInner.ProviderId;
    ASpec.ModelId := FModel;
  end;
end;

function TCompositionProvider.SubmitRevisionRequest(AExistingSpec: TSongSpec;
  AExistingLyrics: TLyricDocument; const AInstruction: string; out ARevisedSpec: TSongSpec;
  out ARevisedLyrics: TLyricDocument; const AScopeTrackIds: TArray<string>;
  const AScopeSectionIds: TArray<string>): Int64;
var
  sysPrompt, userPrompt, currentJSON, scopeText: string;
  writer: TJSONValue;

  function JoinIds(const AIds: TArray<string>): string;
  var
    i: Integer;
  begin
    Result := '';
    for i := 0 to High(AIds) do
    begin
      if i > 0 then Result := Result + ', ';
      Result := Result + AIds[i];
    end;
  end;

begin
  Result := NewRequest(crkRevision);

  if AExistingSpec = nil then
  begin
    SetStatus(Result, crsFailed, 'no existing song specification to revise');
    ARevisedSpec := nil;
    ARevisedLyrics := nil;
    Exit;
  end;

  { Round-trip the current spec through the same JSON shape a fresh
    composition uses, so the AI edits it rather than starting over -
    AIPlan.md section 12: "The AI should never rebuild the entire project
    when only one section was requested." }
  writer := JSONObject;
  try
    writer.AddPair('title', JSONString(AExistingSpec.Meta.Title));
    writer.AddPair('tempo', JSONNumber(AExistingSpec.Meta.Tempo));
    writer.AddPair('key', JSONString(AExistingSpec.Meta.Key));
    writer.AddPair('scale', JSONString(AExistingSpec.Meta.Scale));
    writer.AddPair('sectionCount', JSONNumber(AExistingSpec.Sections.Count));
    writer.AddPair('trackCount', JSONNumber(AExistingSpec.Tracks.Count));
    currentJSON := writer.ToJSONString;
  finally
    writer.Free;
  end;

  sysPrompt :=
    'You are the composition engine of a digital audio workstation, revising an existing song. ' +
    'Reply with ONLY a single JSON object (no prose, no markdown fences) matching exactly this shape: ' +
    BuildSongSpecSchemaText + '. Return the COMPLETE, updated specification, including every ' +
    'section/track/chord-progression that is unchanged, not only what the instruction touched. ' +
    'Keep preferring "type":"audio" (a real sample/loop) over "type":"midi" for any track you add ' +
    'or change, unless the instruction explicitly asks for MIDI/a specific synth or performance style.';

  { AIPlan.md section 17 PHASE 8 "Modify selected tracks or regions": tell
    the AI which ids it may change (best-effort quality hint only - the
    caller-side guarantee is MergeLockedAndOutOfScope, applied below no
    matter what the AI actually returns). }
  scopeText := '';
  if Length(AScopeSectionIds) > 0 then
    scopeText := scopeText + Format(' Only these section ids may be changed: %s.',
      [JoinIds(AScopeSectionIds)]);
  if Length(AScopeTrackIds) > 0 then
    scopeText := scopeText + Format(' Only these track ids may be changed: %s.',
      [JoinIds(AScopeTrackIds)]);
  if scopeText <> '' then
    sysPrompt := sysPrompt + ' This revision is scoped -' + scopeText +
      ' Leave every other section/track exactly as given.';

  userPrompt := Format(
    'Current song (summary): %s'#10#10'Revision instruction: %s',
    [currentJSON, AInstruction]);

  if RunStructuredRequest(Result, sysPrompt, userPrompt, ARevisedSpec, ARevisedLyrics) then
    MergeLockedAndOutOfScope(AExistingSpec, ARevisedSpec, AScopeTrackIds, AScopeSectionIds);
end;

function TCompositionProvider.GenerateLyrics(ASpec: TSongSpec; const ASubject, ALanguage: string;
  out ALyrics: TLyricDocument): Int64;
var
  sysPrompt, userPrompt, sectionsJSON, parseErr, reply, userPromptRetry: string;
  arr, obj: TJSONValue;
  i, attempt: Integer;
begin
  Result := NewRequest(crkLyrics);
  ALyrics := nil;

  if (ASpec = nil) or ASpec.Meta.Instrumental then
  begin
    SetStatus(Result, crsFailed, 'song is instrumental - lyrics were not requested');
    Exit;
  end;

  arr := JSONArray;
  try
    for i := 0 to ASpec.Sections.Count - 1 do
    begin
      obj := JSONObject;
      obj.AddPair('id', JSONString(ASpec.Sections[i].Id));
      obj.AddPair('name', JSONString(ASpec.Sections[i].Name));
      obj.AddPair('lengthBars', JSONNumber(ASpec.Sections[i].LengthBars));
      arr.AddItem(obj);
    end;
    sectionsJSON := arr.ToJSONString;
  finally
    arr.Free;
  end;

  sysPrompt :=
    'You write song lyrics for a digital audio workstation. Reply with ONLY a single JSON object ' +
    '(no prose, no markdown fences) of the shape ' +
    '{"language":string,"sections":[{"sectionId":string,"lines":[{"text":string,"startBar":integer,"durationBars":integer}]}]}.';

  userPrompt := Format(
    'Song sections: %s'#10'Subject: %s'#10'Language: %s',
    [sectionsJSON, ASubject, ALanguage]);

  for attempt := 1 to FMaxRetries + 1 do
  begin
    if not CallWithRetry(Result, sysPrompt, userPrompt, reply) then Exit;
    if ParseLyricsOnlyJSON(reply, ALyrics, parseErr) then
    begin
      SetStatus(Result, crsSucceeded);
      Exit;
    end;
    if attempt > FMaxRetries then
    begin
      SetStatus(Result, crsFailed, parseErr);
      Exit;
    end;
    userPromptRetry := userPrompt + #10#10 +
      'Your previous reply could not be used: ' + parseErr + #10 +
      'Reply again with ONLY the corrected JSON object.';
    userPrompt := userPromptRetry;
  end;
end;

function TCompositionProvider.AnalyzeLyrics(ASpec: TSongSpec; ALyrics: TLyricDocument;
  out AReport: string): Int64;
var
  sysPrompt, userPrompt, lyricsText: string;
  i, j: Integer;
begin
  Result := NewRequest(crkAnalyzeLyrics);
  AReport := '';
  lyricsText := '';
  if ALyrics <> nil then
    for i := 0 to ALyrics.Sections.Count - 1 do
      for j := 0 to ALyrics.Sections[i].Lines.Count - 1 do
        lyricsText := lyricsText + Format('[%s] %s'#10,
          [ALyrics.Sections[i].SectionId, ALyrics.Sections[i].Lines[j].Text]);

  sysPrompt := 'You critique song lyrics for a digital audio workstation. Reply with a short, plain-text report only.';
  userPrompt := 'Lyrics to analyze:'#10 + lyricsText;

  if not CallWithRetry(Result, sysPrompt, userPrompt, AReport) then Exit;
  SetStatus(Result, crsSucceeded);
end;

function TCompositionProvider.AnalyzeArrangement(ASpec: TSongSpec; out AReport: string): Int64;
var
  sysPrompt, userPrompt, secText: string;
  i: Integer;
begin
  Result := NewRequest(crkAnalyzeArrangement);
  AReport := '';
  secText := '';
  if ASpec <> nil then
    for i := 0 to ASpec.Sections.Count - 1 do
      secText := secText + Format('%s: bars %d-%d, energy %.2f'#10,
        [ASpec.Sections[i].Name, ASpec.Sections[i].StartBar,
         ASpec.Sections[i].EndBarExclusive - 1, ASpec.Sections[i].Energy]);

  sysPrompt := 'You critique a song arrangement for a digital audio workstation. Reply with a short, plain-text report only.';
  userPrompt := 'Arrangement sections:'#10 + secText;

  if not CallWithRetry(Result, sysPrompt, userPrompt, AReport) then Exit;
  SetStatus(Result, crsSucceeded);
end;

end.
