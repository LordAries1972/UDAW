unit UDAW.AI.ToolCommands;
{$I udaw.inc}

{ Phase 26 - AI Tool Commands: a SAFE structured command interface (plan
  section 35, docs/UDAW-Original-Plan.txt lines 2160-2231).

  The AI is never allowed to touch project memory directly. Instead its
  reply carries structured intent as a fenced "tool" code block containing a
  small JSON object, e.g. command SetGain with track "drums" and delta_db -2
  (see AIToolSystemPrompt below for the exact wire format shown to the model).

  ParseAIToolCalls extracts every such block from an assistant message and
  parses it with the existing hand-written UDAW.AI.JSON reader (no new JSON
  dependency). ValidateToolCall range-checks the result before anything runs.
  TAIToolDispatcher.Execute then performs the *normal* DAW command for it -
  every mutating tool goes through the Phase 5 TCommandManager exactly like a
  mouse-driven edit, so AI changes participate in Undo/Redo and can never
  manipulate internal state that a validated TDAWCommand would reject.

  Read-only tools (GetProjectInfo, GetTracks, GetMixerState, ...) return a
  JSON string built the same way UDAW.DSP.Analysis serializes analysis
  results, so the model can ground its next answer without the host ever
  having sent raw project internals or audio samples.

  Structural / harder-to-undo tools (AddTrack, SetTempo, ExportProject,
  GenerateMusic) are flagged IsDestructiveTool - the caller (the AI chat
  panel) is expected to ask the user to confirm before calling Execute for
  those, per the plan's "destructive commands must require appropriate
  confirmation". }

interface

uses
  SysUtils, Classes, Math, StrUtils, Generics.Collections,
  UDAW.Errors, UDAW.AI.JSON, UDAW.AI.Credentials,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Mixer.Model, UDAW.Mixer.Commands,
  UDAW.Timeline.Model, UDAW.Timeline.Commands,
  UDAW.Codec.WAV, UDAW.Codec.FLAC, UDAW.Codec.FLAC.Timeline,
  UDAW.Codec.MP3, UDAW.Codec.MP3.Timeline,
  UDAW.Codec.MP4, UDAW.Codec.MP4.Timeline;

const
  AI_TOOL_SUBSYS = 'AI.Tools';

type
  TAIToolKind = (
    atkGetProjectInfo, atkGetTracks, atkGetTrackInfo, atkGetMixerState,
    atkGetSelection, atkAnalyzeAudio,
    atkAddTrack, atkMoveClip, atkSetGain, atkSetPan, atkSetMute, atkSetSolo,
    atkSetTempo, atkAddMarker, atkCreateAutomation, atkGenerateMusic,
    atkSuggestMix, atkExportProject,
    atkFindSample, atkAddSampleToTimeline,
    atkRenameTrack, atkSplitClip, atkDeleteClip, atkSetClipFade,
    atkTransportPlay, atkTransportStop, atkGetAIProviders,
    { the whole application: every menu / toolbar command, the selection those commands act
      on, and the playhead / range they use }
    atkListCommands, atkRunCommand, atkSelectClips, atkSelectTrack,
    atkSetPlayhead, atkSetRange, atkClampClips
  );

  { A parsed, not-yet-validated call. Fields are a flat union of every
    parameter any tool needs; only the ones relevant to Kind are populated
    (from whichever JSON names the model used - the parser accepts a couple
    of reasonable aliases per plan's own example, e.g. "track"/"track_name"). }
  TAIToolCall = record
    Kind: TAIToolKind;
    HasKind: Boolean;
    TrackName: string;
    HasTrackName: Boolean;
    DeltaDb: Double;
    HasDeltaDb: Boolean;
    AbsoluteDb: Double;
    HasAbsoluteDb: Boolean;
    PanValue: Double;
    HasPanValue: Boolean;
    Enabled: Boolean;
    HasEnabled: Boolean;
    TempoBpm: Double;
    HasTempoBpm: Boolean;
    MarkerName: string;
    HasMarkerName: Boolean;
    PositionSec: Double;
    HasPositionSec: Boolean;
    ClipId: Integer;
    HasClipId: Boolean;
    TargetTrackName: string;
    HasTargetTrackName: Boolean;
    ExportPath: string;
    HasExportPath: Boolean;
    Prompt: string;
    HasPrompt: Boolean;
    Criteria: string;
    HasCriteria: Boolean;
    MaxResults: Integer;
    HasMaxResults: Boolean;
    FilePath: string;
    HasFilePath: Boolean;
    FadeInSec: Double;
    HasFadeInSec: Boolean;
    FadeOutSec: Double;
    HasFadeOutSec: Boolean;
    FromBeginning: Boolean;
    HasFromBeginning: Boolean;
    CommandPath: string;
    HasCommandPath: Boolean;
    ClipIds: TArray<Integer>;
    HasClipIds: Boolean;
    StartSec: Double;
    HasStartSec: Boolean;
    EndSec: Double;
    HasEndSec: Boolean;
    Mode: string;
    HasMode: Boolean;
    RawJSON: string;
  end;

function AIToolKindId(AKind: TAIToolKind): string;
function AIToolKindFromId(const AId: string; out AKind: TAIToolKind): Boolean;
function IsDestructiveTool(AKind: TAIToolKind): Boolean;
function IsReadOnlyTool(AKind: TAIToolKind): Boolean;

{ One-line description and parameter list of a tool, used by the MCP server to
  publish a real tools/list. Spec: 'name:type:req|opt:description' entries
  separated by '|'; type is string|number|integer|boolean. }
function AIToolDescription(AKind: TAIToolKind): string;
function AIToolParamSpec(AKind: TAIToolKind): string;

{ Every fenced ```tool ... ``` JSON block found in AText, in order. Blocks
  that fail to parse as JSON or lack a recognised "command" are skipped (not
  raised) - the surrounding chat text is free-form and only well-formed tool
  blocks are actionable. }
function ParseAIToolCalls(const AText: string): TArray<TAIToolCall>;

{ Range/required-field checks. False + AError means the manager must not
  execute the call. }
function ValidateToolCall(const ACall: TAIToolCall; out AError: string): Boolean;

{ System-prompt fragment describing the tool vocabulary and the fenced-block
  protocol, appended to the system message so the model knows how to ask for
  an action instead of only describing one in prose. }
function AIToolSystemPrompt: string;

type
  { Executes a validated call against a live project. Get* tools return a
    JSON string in AResultText; mutating tools perform the equivalent
    TDAWCommand through ACommands and describe what happened in AResultText.
    AnalyzeAudio / SuggestMix / GenerateMusic / ExportProject delegate to the
    optional callbacks (the DAW's audio-rendering / UI layer owns those, not
    this unit) and are no-ops (with an explanatory AResultText) if the
    relevant callback is not assigned. }
  TAIAnalyzeTrackFunc = function(const ATrackName: string): string of object;
  TAIExportProjectFunc = function: string of object;
  TAISuggestMixFunc = function: string of object;
  TAIGenerateMusicFunc = function(const APrompt: string): string of object;

  { The Browser tab (UDAW.UI.MainForm) owns the live list of folders the user
    has added there; this unit deliberately has no UI dependency (mirrors the
    OnGetDoc/OnGetCommands callback shape UDAW.AI.MCPServer.TUDAWMcpServer
    already uses for the same layering reason), so the host wires this in
    rather than the dispatcher reaching into MainForm itself. }
  TAIGetBrowserRootsFunc = function: TArray<string> of object;

  { Transport control lives in the UI layer (the live TTimelinePlayer).
    AAction is 'play' or 'stop'; returns a short result text. }
  TAITransportFunc = function(const AAction: string; AFromBeginning: Boolean): string of object;

  { The application-level tools (ListCommands, RunCommand, SelectClips, SelectTrack, SetPlayhead,
    SetRange, ClampClips) act on the live window, which only the UI layer owns. It receives the
    whole call and returns a JSON result; a result holding an "error" member counts as a failure. }
  TAIUICommandFunc = function(const ACall: TAIToolCall): string of object;

  TAIToolDispatcher = class
  private
    FDoc: TProjectDocument;
    FCommands: TCommandManager;
    FOnAnalyzeAudio: TAIAnalyzeTrackFunc;
    FOnExportProject: TAIExportProjectFunc;
    FOnSuggestMix: TAISuggestMixFunc;
    FOnGenerateMusic: TAIGenerateMusicFunc;
    FOnGetBrowserRoots: TAIGetBrowserRootsFunc;
    FOnTransport: TAITransportFunc;
    FOnUICommand: TAIUICommandFunc;
    function FindStripByName(const AName: string): TMixStrip;
    function FindTrackByName(const AName: string): TTimelineTrack;
    function BuildProjectInfoJSON: string;
    function BuildTracksJSON: string;
    function BuildTrackInfoJSON(const AName: string): string;
    function BuildMixerStateJSON: string;
    function BuildAIProvidersJSON: string;
    function BuildFindSampleJSON(const ACriteria: string; AMaxResults: Integer): string;
    function ResolvePathUnderBrowserRoots(const APath: string; out AFullPath: string): Boolean;
    function PerformAddSampleToTimeline(const ACall: TAIToolCall; out AResultText: string): Boolean;
  public
    constructor Create(ADoc: TProjectDocument; ACommands: TCommandManager);

    { Execute a single validated call. Returns True if it ran (or was a
      successful read), False on a resolvable failure (e.g. unknown track) -
      AResultText always explains what happened either way. }
    function Execute(const ACall: TAIToolCall; out AResultText: string): Boolean;

    property OnAnalyzeAudio: TAIAnalyzeTrackFunc read FOnAnalyzeAudio write FOnAnalyzeAudio;
    property OnExportProject: TAIExportProjectFunc read FOnExportProject write FOnExportProject;
    property OnSuggestMix: TAISuggestMixFunc read FOnSuggestMix write FOnSuggestMix;
    property OnGenerateMusic: TAIGenerateMusicFunc read FOnGenerateMusic write FOnGenerateMusic;
    property OnGetBrowserRoots: TAIGetBrowserRootsFunc read FOnGetBrowserRoots write FOnGetBrowserRoots;
    property OnTransport: TAITransportFunc read FOnTransport write FOnTransport;
    property OnUICommand: TAIUICommandFunc read FOnUICommand write FOnUICommand;
  end;

implementation

{ ================= name maps ================= }

function AIToolKindId(AKind: TAIToolKind): string;
begin
  case AKind of
    atkGetProjectInfo:   Result := 'GetProjectInfo';
    atkGetTracks:        Result := 'GetTracks';
    atkGetTrackInfo:     Result := 'GetTrackInfo';
    atkGetMixerState:    Result := 'GetMixerState';
    atkGetSelection:     Result := 'GetSelection';
    atkAnalyzeAudio:     Result := 'AnalyzeAudio';
    atkAddTrack:         Result := 'AddTrack';
    atkMoveClip:         Result := 'MoveClip';
    atkSetGain:          Result := 'SetGain';
    atkSetPan:           Result := 'SetPan';
    atkSetMute:          Result := 'SetMute';
    atkSetSolo:          Result := 'SetSolo';
    atkSetTempo:         Result := 'SetTempo';
    atkAddMarker:        Result := 'AddMarker';
    atkCreateAutomation: Result := 'CreateAutomation';
    atkGenerateMusic:    Result := 'GenerateMusic';
    atkSuggestMix:       Result := 'SuggestMix';
    atkExportProject:    Result := 'ExportProject';
    atkFindSample:       Result := 'FindSample';
    atkAddSampleToTimeline: Result := 'AddSampleToTimeline';
    atkRenameTrack:      Result := 'RenameTrack';
    atkSplitClip:        Result := 'SplitClip';
    atkDeleteClip:       Result := 'DeleteClip';
    atkSetClipFade:      Result := 'SetClipFade';
    atkTransportPlay:    Result := 'TransportPlay';
    atkTransportStop:    Result := 'TransportStop';
    atkGetAIProviders:   Result := 'GetAIProviders';
    atkListCommands:     Result := 'ListCommands';
    atkRunCommand:       Result := 'RunCommand';
    atkSelectClips:      Result := 'SelectClips';
    atkSelectTrack:      Result := 'SelectTrack';
    atkSetPlayhead:      Result := 'SetPlayhead';
    atkSetRange:         Result := 'SetRange';
    atkClampClips:       Result := 'ClampClips';
  else
    Result := '?';
  end;
end;

function AIToolKindFromId(const AId: string; out AKind: TAIToolKind): Boolean;
var
  k: TAIToolKind;
  id: string;
begin
  id := Trim(AId);
  { plan's own worked example uses the snake_case "set_track_gain" for what
    the tool table calls SetGain - accept either spelling. }
  if SameText(id, 'set_track_gain') then id := 'SetGain'
  else if SameText(id, 'set_track_pan') then id := 'SetPan'
  else if SameText(id, 'set_track_mute') then id := 'SetMute'
  else if SameText(id, 'set_track_solo') then id := 'SetSolo'
  else if SameText(id, 'add_track') then id := 'AddTrack'
  else if SameText(id, 'set_tempo') then id := 'SetTempo';

  for k := Low(TAIToolKind) to High(TAIToolKind) do
    if SameText(id, AIToolKindId(k)) then
    begin
      AKind := k;
      Exit(True);
    end;
  Result := False;
end;

function IsDestructiveTool(AKind: TAIToolKind): Boolean;
begin
  Result := AKind in [atkAddTrack, atkMoveClip, atkSetTempo, atkExportProject,
    atkGenerateMusic, atkAddSampleToTimeline, atkDeleteClip,
    atkRunCommand, atkClampClips];
end;

function IsReadOnlyTool(AKind: TAIToolKind): Boolean;
begin
  Result := AKind in [atkGetProjectInfo, atkGetTracks, atkGetTrackInfo,
    atkGetMixerState, atkGetSelection, atkAnalyzeAudio, atkSuggestMix,
    atkFindSample, atkGetAIProviders, atkTransportStop, atkListCommands];
end;

function AIToolDescription(AKind: TAIToolKind): string;
begin
  case AKind of
    atkGetProjectInfo:   Result := 'Project name, tempo, track/clip counts.';
    atkGetTracks:        Result := 'List every timeline track with its clips.';
    atkGetTrackInfo:     Result := 'Details of one track.';
    atkGetMixerState:    Result := 'Fader, pan, mute, solo of every mixer strip.';
    atkGetSelection:     Result := 'Current selection (not exposed yet).';
    atkAnalyzeAudio:     Result := 'Loudness/peak analysis of one track.';
    atkAddTrack:         Result := 'Add a new audio track.';
    atkMoveClip:         Result := 'Move a clip to a new position (and optionally track).';
    atkSetGain:          Result := 'Set or nudge a strip fader in dB.';
    atkSetPan:           Result := 'Set a strip pan (-1 left .. 1 right).';
    atkSetMute:          Result := 'Mute or unmute a strip.';
    atkSetSolo:          Result := 'Solo or unsolo a strip.';
    atkSetTempo:         Result := 'Set the project tempo in BPM.';
    atkAddMarker:        Result := 'Add a named timeline marker.';
    atkCreateAutomation: Result := 'Put a strip into automation Write mode.';
    atkGenerateMusic:    Result := 'Generate music from a text prompt (AI provider).';
    atkSuggestMix:       Result := 'Heuristic mixing suggestions for the project.';
    atkExportProject:    Result := 'Export/render the project.';
    atkFindSample:       Result := 'Search the Browser folders for audio files by keyword.';
    atkAddSampleToTimeline: Result := 'Place a sample from a Browser folder on a track as a clip.';
    atkRenameTrack:      Result := 'Rename a timeline track.';
    atkSplitClip:        Result := 'Split a clip in two at a time position.';
    atkDeleteClip:       Result := 'Delete a clip from the timeline.';
    atkSetClipFade:      Result := 'Set a clip fade-in and/or fade-out length in seconds.';
    atkTransportPlay:    Result := 'Start timeline playback.';
    atkTransportStop:    Result := 'Stop timeline playback (playhead rewinds to 0).';
    atkGetAIProviders:   Result := 'Which AI providers have a stored credential (never returns the key).';
    atkListCommands:     Result := 'List every command of the application (menus, popup menus, toolbar and icon buttons) with its path, whether it is enabled right now, and whether it opens a dialog. Optional criteria filters by words.';
    atkRunCommand:       Result := 'Run one command from ListCommands by its path (or a unique ending of it), exactly as if the user had clicked it. Commands act on the current selection, playhead and range - set those first with SelectClips, SelectTrack, SetPlayhead and SetRange. Commands that open a dialog are refused.';
    atkSelectClips:      Result := 'Select one or more Timeline clips (replaces the selection); the first id is the primary clip.';
    atkSelectTrack:      Result := 'Select a Timeline track (lane) by name.';
    atkSetPlayhead:      Result := 'Move the Timeline playhead to a time in seconds.';
    atkSetRange:         Result := 'Set the Timeline time-range selection (start and end in seconds), or clear it.';
    atkClampClips:       Result := 'Slide clips along their own lane so each sits snug against the end of the previous clip (mode "last") or so its end meets the start of the next clip (mode "next") - gap-free playback.';
  else
    Result := AIToolKindId(AKind);
  end;
end;

function AIToolParamSpec(AKind: TAIToolKind): string;
begin
  case AKind of
    atkGetTrackInfo, atkAnalyzeAudio:
      Result := 'track:string:req:Track name';
    atkAddTrack:
      Result := 'track:string:req:New track name';
    atkMoveClip:
      Result := 'clip_id:integer:req:Clip id|position_sec:number:req:New start (s)|target_track:string:opt:Destination track';
    atkSetGain:
      Result := 'track:string:req:Track or strip name|delta_db:number:opt:Relative change dB (-120..24)|gain_db:number:opt:Absolute dB (-120..24)';
    atkSetPan:
      Result := 'track:string:req:Track or strip name|pan:number:req:-1..1';
    atkSetMute, atkSetSolo:
      Result := 'track:string:req:Track or strip name|enabled:boolean:opt:Default true';
    atkSetTempo:
      Result := 'bpm:number:req:20..400';
    atkAddMarker:
      Result := 'name:string:req:Marker name|position_sec:number:opt:Default 0';
    atkCreateAutomation:
      Result := 'track:string:req:Track or strip name';
    atkGenerateMusic:
      Result := 'prompt:string:req:Music description';
    atkFindSample:
      Result := 'criteria:string:req:Keywords|max_results:integer:opt:Result cap';
    atkAddSampleToTimeline:
      Result := 'path:string:req:File from FindSample|track:string:req:Existing track|position_sec:number:opt:Default 0';
    atkRenameTrack:
      Result := 'track:string:req:Current name|name:string:req:New name';
    atkSplitClip:
      Result := 'clip_id:integer:req:Clip id|position_sec:number:req:Split time (s)';
    atkDeleteClip:
      Result := 'clip_id:integer:req:Clip id';
    atkSetClipFade:
      Result := 'clip_id:integer:req:Clip id|fade_in_sec:number:opt:Fade-in seconds|fade_out_sec:number:opt:Fade-out seconds';
    atkTransportPlay:
      Result := 'from_beginning:boolean:opt:Start at 0 instead of the current position';
    atkListCommands:
      Result := 'criteria:string:opt:Only commands whose path contains one of these words';
    atkRunCommand:
      Result := 'menu_path:string:req:Command path from ListCommands, e.g. Timeline > Edit > Clamp to > Clamp to Next Segment';
    atkSelectClips:
      Result := 'clip_ids:array:req:Clip ids (numbers)';
    atkSelectTrack:
      Result := 'track:string:req:Track name';
    atkSetPlayhead:
      Result := 'position_sec:number:req:Time in seconds (>= 0)';
    atkSetRange:
      Result := 'start_sec:number:opt:Range start (s)|end_sec:number:opt:Range end (s)|enabled:boolean:opt:false clears the range';
    atkClampClips:
      Result := 'clip_ids:array:req:Clip ids (numbers)|mode:string:req:"last" or "next"';
  else
    Result := '';
  end;
end;

{ ================= parsing ================= }

function JStr(AObj: TJSONValue; const AName: string; out AValue: string): Boolean;
var
  v: TJSONValue;
begin
  Result := False;
  if AObj = nil then Exit;
  v := AObj.ByName(AName);
  if (v <> nil) and (v.Kind = jkString) then
  begin
    AValue := v.AsString;
    Result := True;
  end;
end;

function JNum(AObj: TJSONValue; const AName: string; out AValue: Double): Boolean;
var
  v: TJSONValue;
begin
  Result := False;
  if AObj = nil then Exit;
  v := AObj.ByName(AName);
  if (v <> nil) and (v.Kind = jkNumber) then
  begin
    AValue := v.AsNumber;
    Result := True;
  end;
end;

function JBool(AObj: TJSONValue; const AName: string; out AValue: Boolean): Boolean;
var
  v: TJSONValue;
begin
  Result := False;
  if AObj = nil then Exit;
  v := AObj.ByName(AName);
  if (v <> nil) and (v.Kind = jkBool) then
  begin
    AValue := v.AsBool;
    Result := True;
  end;
end;

function ParseOneToolCall(const AJSON: string; out ACall: TAIToolCall): Boolean;
var
  v, cmdV, ids: TJSONValue;
  cmdId, s: string;
  num: Double;
  b: Boolean;
  k: Integer;
begin
  Finalize(ACall);
  FillChar(ACall, SizeOf(ACall), 0);
  ACall.RawJSON := AJSON;
  try
    v := UDAW.AI.JSON.Parse(AJSON);
  except
    Exit(False);
  end;
  try
    if (v = nil) or (v.Kind <> jkObject) then Exit(False);
    cmdV := v.ByName('command');
    if (cmdV = nil) or (cmdV.Kind <> jkString) then Exit(False);
    cmdId := cmdV.AsString;
    if not AIToolKindFromId(cmdId, ACall.Kind) then Exit(False);
    ACall.HasKind := True;

    if JStr(v, 'track', s) or JStr(v, 'track_name', s) then
    begin ACall.TrackName := s; ACall.HasTrackName := True; end;
    if JNum(v, 'delta_db', num) then
    begin ACall.DeltaDb := num; ACall.HasDeltaDb := True; end;
    if JNum(v, 'gain_db', num) or JNum(v, 'value_db', num) then
    begin ACall.AbsoluteDb := num; ACall.HasAbsoluteDb := True; end;
    if JNum(v, 'pan', num) then
    begin ACall.PanValue := num; ACall.HasPanValue := True; end;
    if JBool(v, 'enabled', b) or JBool(v, 'value', b) then
    begin ACall.Enabled := b; ACall.HasEnabled := True; end;
    if JNum(v, 'bpm', num) or JNum(v, 'tempo', num) then
    begin ACall.TempoBpm := num; ACall.HasTempoBpm := True; end;
    if JStr(v, 'name', s) or JStr(v, 'marker', s) then
    begin ACall.MarkerName := s; ACall.HasMarkerName := True; end;
    if JNum(v, 'position_sec', num) or JNum(v, 'seconds', num) then
    begin ACall.PositionSec := num; ACall.HasPositionSec := True; end;
    if JNum(v, 'clip_id', num) then
    begin ACall.ClipId := Round(num); ACall.HasClipId := True; end;
    if JStr(v, 'target_track', s) then
    begin ACall.TargetTrackName := s; ACall.HasTargetTrackName := True; end;
    if JStr(v, 'path', s) then
    begin
      ACall.ExportPath := s; ACall.HasExportPath := True;
      ACall.FilePath := s; ACall.HasFilePath := True;
    end
    else if JStr(v, 'export_path', s) then
    begin ACall.ExportPath := s; ACall.HasExportPath := True; end;
    if JStr(v, 'sample_path', s) then
    begin ACall.FilePath := s; ACall.HasFilePath := True; end;
    if JStr(v, 'prompt', s) then
    begin ACall.Prompt := s; ACall.HasPrompt := True; end;
    if JStr(v, 'criteria', s) then
    begin ACall.Criteria := s; ACall.HasCriteria := True; end;
    if JNum(v, 'max_results', num) or JNum(v, 'limit', num) then
    begin ACall.MaxResults := Round(num); ACall.HasMaxResults := True; end;
    if JNum(v, 'fade_in_sec', num) then
    begin ACall.FadeInSec := num; ACall.HasFadeInSec := True; end;
    if JNum(v, 'fade_out_sec', num) then
    begin ACall.FadeOutSec := num; ACall.HasFadeOutSec := True; end;
    if JBool(v, 'from_beginning', b) then
    begin ACall.FromBeginning := b; ACall.HasFromBeginning := True; end;
    if JStr(v, 'menu_path', s) or JStr(v, 'command_path', s) then
    begin ACall.CommandPath := s; ACall.HasCommandPath := True; end;
    if JNum(v, 'start_sec', num) then
    begin ACall.StartSec := num; ACall.HasStartSec := True; end;
    if JNum(v, 'end_sec', num) then
    begin ACall.EndSec := num; ACall.HasEndSec := True; end;
    if JStr(v, 'mode', s) then
    begin ACall.Mode := s; ACall.HasMode := True; end;
    ids := v.ByName('clip_ids');
    if (ids <> nil) and (ids.Kind = jkArray) then
    begin
      SetLength(ACall.ClipIds, 0);
      for k := 0 to ids.Count - 1 do
        if ids.Items[k].Kind = jkNumber then
          ACall.ClipIds := ACall.ClipIds + [Round(ids.Items[k].AsNumber)];
      ACall.HasClipIds := Length(ACall.ClipIds) > 0;
    end
    else if ACall.HasClipId then
    begin
      { a single clip_id stands in for a list of one }
      ACall.ClipIds := [ACall.ClipId];
      ACall.HasClipIds := True;
    end;

    Result := True;
  finally
    v.Free;
  end;
end;

function ParseAIToolCalls(const AText: string): TArray<TAIToolCall>;
const
  FENCE_OPEN = '```tool';
  FENCE_CLOSE = '```';
var
  list: TList<TAIToolCall>;
  pos, openAt, bodyStart, closeAt: Integer;
  body: string;
  call: TAIToolCall;
begin
  list := TList<TAIToolCall>.Create;
  try
    pos := 1;
    while True do
    begin
      openAt := System.Pos(FENCE_OPEN, AText, pos);
      if openAt = 0 then Break;
      bodyStart := openAt + Length(FENCE_OPEN);
      closeAt := System.Pos(FENCE_CLOSE, AText, bodyStart);
      if closeAt = 0 then Break;
      body := Trim(Copy(AText, bodyStart, closeAt - bodyStart));
      if ParseOneToolCall(body, call) then
        list.Add(call);
      pos := closeAt + Length(FENCE_CLOSE);
    end;
    Result := list.ToArray;
  finally
    list.Free;
  end;
end;

{ ================= validation ================= }

function ValidateToolCall(const ACall: TAIToolCall; out AError: string): Boolean;
begin
  AError := '';
  if not ACall.HasKind then
  begin
    AError := 'unrecognised or missing "command"';
    Exit(False);
  end;
  case ACall.Kind of
    atkGetTrackInfo, atkAnalyzeAudio, atkSetMute, atkSetSolo:
      if not ACall.HasTrackName then
      begin AError := 'missing "track"'; Exit(False); end;
    atkSetGain:
      begin
        if not ACall.HasTrackName then
        begin AError := 'missing "track"'; Exit(False); end;
        if not (ACall.HasDeltaDb or ACall.HasAbsoluteDb) then
        begin AError := 'missing "delta_db" or "gain_db"'; Exit(False); end;
        if ACall.HasDeltaDb and ((ACall.DeltaDb < -120) or (ACall.DeltaDb > 24)) then
        begin AError := 'delta_db out of range (-120..24)'; Exit(False); end;
        if ACall.HasAbsoluteDb and ((ACall.AbsoluteDb < -120) or (ACall.AbsoluteDb > 24)) then
        begin AError := 'gain_db out of range (-120..24)'; Exit(False); end;
      end;
    atkSetPan:
      begin
        if not ACall.HasTrackName then
        begin AError := 'missing "track"'; Exit(False); end;
        if not ACall.HasPanValue then
        begin AError := 'missing "pan"'; Exit(False); end;
        if (ACall.PanValue < -1.0) or (ACall.PanValue > 1.0) then
        begin AError := 'pan out of range (-1..1)'; Exit(False); end;
      end;
    atkSetTempo:
      begin
        if not ACall.HasTempoBpm then
        begin AError := 'missing "bpm"'; Exit(False); end;
        if (ACall.TempoBpm < 20) or (ACall.TempoBpm > 400) then
        begin AError := 'bpm out of range (20..400)'; Exit(False); end;
      end;
    atkAddTrack:
      if not ACall.HasTrackName then
      begin AError := 'missing "track" (new track name)'; Exit(False); end;
    atkAddMarker:
      if not ACall.HasMarkerName then
      begin AError := 'missing "name" (marker name)'; Exit(False); end;
    atkMoveClip:
      begin
        if not ACall.HasClipId then
        begin AError := 'missing "clip_id"'; Exit(False); end;
        if not ACall.HasPositionSec then
        begin AError := 'missing "position_sec"'; Exit(False); end;
        if ACall.PositionSec < 0 then
        begin AError := 'position_sec must be >= 0'; Exit(False); end;
      end;
    atkCreateAutomation:
      if not ACall.HasTrackName then
      begin AError := 'missing "track"'; Exit(False); end;
    atkRenameTrack:
      begin
        if not ACall.HasTrackName then
        begin AError := 'missing "track"'; Exit(False); end;
        if (not ACall.HasMarkerName) or (Trim(ACall.MarkerName) = '') then
        begin AError := 'missing "name" (new track name)'; Exit(False); end;
      end;
    atkSplitClip:
      begin
        if not ACall.HasClipId then
        begin AError := 'missing "clip_id"'; Exit(False); end;
        if (not ACall.HasPositionSec) or (ACall.PositionSec < 0) then
        begin AError := 'missing or negative "position_sec"'; Exit(False); end;
      end;
    atkDeleteClip:
      if not ACall.HasClipId then
      begin AError := 'missing "clip_id"'; Exit(False); end;
    atkSetClipFade:
      begin
        if not ACall.HasClipId then
        begin AError := 'missing "clip_id"'; Exit(False); end;
        if not (ACall.HasFadeInSec or ACall.HasFadeOutSec) then
        begin AError := 'missing "fade_in_sec" or "fade_out_sec"'; Exit(False); end;
        if (ACall.HasFadeInSec and (ACall.FadeInSec < 0)) or
           (ACall.HasFadeOutSec and (ACall.FadeOutSec < 0)) then
        begin AError := 'fade lengths must be >= 0'; Exit(False); end;
      end;
    atkFindSample:
      if (not ACall.HasCriteria) or (Trim(ACall.Criteria) = '') then
      begin AError := 'missing "criteria"'; Exit(False); end;
    atkRunCommand:
      if (not ACall.HasCommandPath) or (Trim(ACall.CommandPath) = '') then
      begin AError := 'missing "menu_path" (a path from ListCommands)'; Exit(False); end;
    atkSelectClips:
      if not ACall.HasClipIds then
      begin AError := 'missing "clip_ids"'; Exit(False); end;
    atkSelectTrack:
      if (not ACall.HasTrackName) or (Trim(ACall.TrackName) = '') then
      begin AError := 'missing "track"'; Exit(False); end;
    atkSetPlayhead:
      begin
        if not ACall.HasPositionSec then
        begin AError := 'missing "position_sec"'; Exit(False); end;
        if ACall.PositionSec < 0 then
        begin AError := 'position_sec must be >= 0'; Exit(False); end;
      end;
    atkSetRange:
      if (not ACall.HasEnabled) or ACall.Enabled then
      begin
        if not (ACall.HasStartSec and ACall.HasEndSec) then
        begin AError := 'missing "start_sec" and "end_sec"'; Exit(False); end;
        if (ACall.StartSec < 0) or (ACall.EndSec <= ACall.StartSec) then
        begin AError := 'start_sec must be >= 0 and end_sec after it'; Exit(False); end;
      end;
    atkClampClips:
      begin
        if not ACall.HasClipIds then
        begin AError := 'missing "clip_ids"'; Exit(False); end;
        if not (SameText(ACall.Mode, 'last') or SameText(ACall.Mode, 'next')) then
        begin AError := '"mode" must be "last" or "next"'; Exit(False); end;
      end;
    atkAddSampleToTimeline:
      begin
        if (not ACall.HasFilePath) or (Trim(ACall.FilePath) = '') then
        begin AError := 'missing "path"'; Exit(False); end;
        if not ACall.HasTrackName then
        begin AError := 'missing "track"'; Exit(False); end;
        if ACall.HasPositionSec and (ACall.PositionSec < 0) then
        begin AError := 'position_sec must be >= 0'; Exit(False); end;
      end;
  end;
  Result := True;
end;

{ ================= system prompt ================= }

function AIToolSystemPrompt: string;
begin
  Result :=
    'You can operate this DAW by emitting a fenced tool block anywhere in your reply: ' +
    '```tool' + sLineBreak +
    '{"command":"SetGain","track":"drums","delta_db":-2}' + sLineBreak +
    '```' + sLineBreak +
    'Available commands: GetProjectInfo, GetTracks, GetTrackInfo{track}, ' +
    'GetMixerState, GetSelection, AnalyzeAudio{track}, AddTrack{track}, ' +
    'MoveClip{clip_id,position_sec}, SetGain{track,delta_db|gain_db}, ' +
    'SetPan{track,pan(-1..1)}, SetMute{track,enabled}, SetSolo{track,enabled}, ' +
    'SetTempo{bpm}, AddMarker{name,position_sec}, CreateAutomation{track}, ' +
    'GenerateMusic{prompt}, SuggestMix, ExportProject{path}, ' +
    'FindSample{criteria,max_results}, ' +
    'AddSampleToTimeline{path,track,position_sec}, RenameTrack{track,name}, ' +
    'SplitClip{clip_id,position_sec}, DeleteClip{clip_id}, ' +
    'SetClipFade{clip_id,fade_in_sec,fade_out_sec}, TransportPlay{from_beginning}, ' +
    'TransportStop, GetAIProviders, ' +
    'ListCommands{criteria}, RunCommand{menu_path}, SelectClips{clip_ids[]}, ' +
    'SelectTrack{track}, SetPlayhead{position_sec}, SetRange{start_sec,end_sec|enabled:false}, ' +
    'ClampClips{clip_ids[],mode:last|next}. ' +
    'ListCommands returns every command of the application (every menu, popup menu, toolbar ' +
    'and icon button) with its "path", "enabled" and "dialog" flags; RunCommand runs one by ' +
    'its path exactly as a click would, acting on the current selection, playhead and range, ' +
    'so set those first with SelectClips / SelectTrack / SetPlayhead / SetRange. Commands ' +
    'that open a dialog need a person and are refused. ' +
    'FindSample searches every folder the user has added to the Browser tab ' +
    '(recursively) for audio files whose file name or containing folder name ' +
    'contains a word from criteria, e.g. ' +
    '```tool' + sLineBreak +
    '{"command":"FindSample","criteria":"punchy kick","max_results":10}' + sLineBreak +
    '```' + sLineBreak +
    'and returns JSON {"count":N,"samples":[{"path":...,"name":...,"folder":..., ' +
    '"duration_sec":...,"sample_rate":...,"channels":...}, ...]} (duration/rate/channels ' +
    'are omitted if the file could not be probed). Use these fields to judge whether a ' +
    'result is actually musical material before placing it: a file under ~0.05s is a ' +
    'click/transient, not a usable note, bass hit or pad; a folder literally named things ' +
    'like "SFX"/"FX"/"Foley" is sound-effects material, not music, and should be used only ' +
    'if the brief explicitly calls for a sound effect - prefer results from folders that ' +
    'read as instrument/loop/sample libraries for drum, bass, melody and pad parts. If ' +
    'FindSample only turns up SFX-folder or implausibly short results for a musical part, ' +
    'try a different, more specific criteria before giving up on that part. ' +
    'AddSampleToTimeline takes a "path" from a prior FindSample result (paths ' +
    'outside a registered Browser folder are refused), an existing "track" name ' +
    '(add one first with AddTrack if it does not exist yet), and an optional ' +
    '"position_sec" (seconds, default 0), e.g. ' +
    '```tool' + sLineBreak +
    '{"command":"AddSampleToTimeline","path":"G:\\Studio\\mine\\Kicks\\Kick1.wav",' +
    '"track":"Drums","position_sec":4}' + sLineBreak +
    '```' + sLineBreak +
    'and adds the file as a new non-destructive Timeline clip through the same ' +
    'undo-aware import path the Browser''s own drag-and-drop uses. ' +
    'Running FindSample or AddTrack never puts audio on the timeline by itself - a track with ' +
    'no clips is silent. Whenever a task calls for material to actually be heard, you must ' +
    'commit: for each part, say in plain text exactly which file (its "path") you are choosing ' +
    'from the FindSample results and why, then follow that sentence with the matching ' +
    'AddSampleToTimeline call in the same reply. Never end a reply having only searched or only ' +
    'created empty tracks when the task needs audible material. ' +
    'Every command is validated and applied through the DAW''s own undo-aware ' +
    'edit commands - you never touch project data directly. Use Get* commands ' +
    'first to ground your answer in real project state before suggesting changes.';
end;

{ ================= TAIToolDispatcher ================= }

constructor TAIToolDispatcher.Create(ADoc: TProjectDocument; ACommands: TCommandManager);
begin
  inherited Create;
  FDoc := ADoc;
  FCommands := ACommands;
end;

function TAIToolDispatcher.FindStripByName(const AName: string): TMixStrip;
var
  i: Integer;
  s: TMixStrip;
  needle: string;
begin
  Result := nil;
  needle := Trim(AName);
  if needle = '' then Exit;
  for i := 0 to FDoc.Mixer.StripCount - 1 do
  begin
    s := FDoc.Mixer.GetStrip(i);
    if SameText(s.Name, needle) then Exit(s);
  end;
  for i := 0 to FDoc.Mixer.StripCount - 1 do
  begin
    s := FDoc.Mixer.GetStrip(i);
    if ContainsText(s.Name, needle) then Exit(s);
  end;
end;

function TAIToolDispatcher.FindTrackByName(const AName: string): TTimelineTrack;
var
  i: Integer;
  t: TTimelineTrack;
  needle: string;
begin
  Result := nil;
  needle := Trim(AName);
  if needle = '' then Exit;
  for i := 0 to FDoc.Timeline.TrackCount - 1 do
  begin
    t := FDoc.Timeline.GetTrack(i);
    if SameText(t.Name, needle) then Exit(t);
  end;
  for i := 0 to FDoc.Timeline.TrackCount - 1 do
  begin
    t := FDoc.Timeline.GetTrack(i);
    if ContainsText(t.Name, needle) then Exit(t);
  end;
end;

function TAIToolDispatcher.BuildProjectInfoJSON: string;
var
  o: TJSONValue;
begin
  o := JSONObject;
  try
    o.AddPair('name', JSONString(FDoc.Name));
    o.AddPair('tempo_bpm', JSONNumber(FDoc.TempoBPM));
    o.AddPair('time_sig_num', JSONNumber(FDoc.TimeSigNum));
    o.AddPair('time_sig_den', JSONNumber(FDoc.TimeSigDen));
    o.AddPair('track_count', JSONNumber(FDoc.Timeline.TrackCount));
    o.AddPair('clip_count', JSONNumber(FDoc.Timeline.ClipCountTotal));
    o.AddPair('mixer_strip_count', JSONNumber(FDoc.Mixer.StripCount));
    Result := o.ToJSONString;
  finally
    o.Free;
  end;
end;

function TAIToolDispatcher.BuildTracksJSON: string;
var
  o, arr, t: TJSONValue;
  i: Integer;
  trk: TTimelineTrack;
begin
  o := JSONObject;
  try
    arr := JSONArray;
    for i := 0 to FDoc.Timeline.TrackCount - 1 do
    begin
      trk := FDoc.Timeline.GetTrack(i);
      t := JSONObject;
      t.AddPair('id', JSONNumber(trk.Id));
      t.AddPair('name', JSONString(trk.Name));
      t.AddPair('clip_count', JSONNumber(trk.ClipCount));
      arr.AddItem(t);
    end;
    o.AddPair('tracks', arr);
    Result := o.ToJSONString;
  finally
    o.Free;
  end;
end;

function TAIToolDispatcher.BuildTrackInfoJSON(const AName: string): string;
var
  o: TJSONValue;
  trk: TTimelineTrack;
  strip: TMixStrip;
begin
  o := JSONObject;
  try
    trk := FindTrackByName(AName);
    if trk = nil then
    begin
      o.AddPair('error', JSONString('no timeline track matches "' + AName + '"'));
      Exit(o.ToJSONString);
    end;
    o.AddPair('id', JSONNumber(trk.Id));
    o.AddPair('name', JSONString(trk.Name));
    o.AddPair('clip_count', JSONNumber(trk.ClipCount));
    o.AddPair('muted', JSONBool(trk.Muted));
    o.AddPair('soloed', JSONBool(trk.Soloed));
    strip := FindStripByName(AName);
    if strip <> nil then
    begin
      o.AddPair('mixer_fader_db', JSONNumber(strip.FaderDb));
      o.AddPair('mixer_pan', JSONNumber(strip.Pan));
      o.AddPair('mixer_muted', JSONBool(strip.Muted));
      o.AddPair('mixer_soloed', JSONBool(strip.Soloed));
    end;
    Result := o.ToJSONString;
  finally
    o.Free;
  end;
end;

function TAIToolDispatcher.BuildAIProvidersJSON: string;
var
  i: Integer;
begin
  { Reports only WHETHER a credential is stored - the key itself never leaves
    the OS secure store through this path. }
  Result := '{"providers":[';
  for i := Low(AI_KNOWN_PROVIDERS) to High(AI_KNOWN_PROVIDERS) do
  begin
    if i > Low(AI_KNOWN_PROVIDERS) then Result := Result + ',';
    Result := Result + Format('{"id":"%s","name":"%s","has_key":%s}',
      [AI_KNOWN_PROVIDERS[i], AIProviderDisplayName(AI_KNOWN_PROVIDERS[i]),
       IfThen(HasAIApiKey(AI_KNOWN_PROVIDERS[i]), 'true', 'false')]);
  end;
  Result := Result + ']}';
end;

function TAIToolDispatcher.BuildMixerStateJSON: string;
var
  o, arr, s: TJSONValue;
  i: Integer;
  strip: TMixStrip;
begin
  o := JSONObject;
  try
    arr := JSONArray;
    for i := 0 to FDoc.Mixer.StripCount - 1 do
    begin
      strip := FDoc.Mixer.GetStrip(i);
      s := JSONObject;
      s.AddPair('id', JSONNumber(strip.Id));
      s.AddPair('name', JSONString(strip.Name));
      s.AddPair('kind', JSONString(MixStripKindId(strip.Kind)));
      s.AddPair('fader_db', JSONNumber(strip.FaderDb));
      s.AddPair('pan', JSONNumber(strip.Pan));
      s.AddPair('muted', JSONBool(strip.Muted));
      s.AddPair('soloed', JSONBool(strip.Soloed));
      s.AddPair('insert_count', JSONNumber(strip.InsertCount));
      arr.AddItem(s);
    end;
    o.AddPair('strips', arr);
    Result := o.ToJSONString;
  finally
    o.Free;
  end;
end;

{ ================= sample search / placement ================= }

const
  FIND_SAMPLE_MAX_RESULTS = 20;

{ Mirrors UDAW.UI.MainForm.TfrmMain.BrowserIsAudioExt's extension list. This
  unit must not depend on the UI layer (MainForm depends on this unit, not the
  other way round), so the list is duplicated rather than shared - keep both
  in sync if the Browser ever learns a new importable format. }
function ToolIsAudioExt(const AExt: string): Boolean;
begin
  Result := (AExt = '.wav') or (AExt = '.flac') or (AExt = '.mp3') or
    (AExt = '.mp4') or (AExt = '.m4a') or (AExt = '.m4v') or (AExt = '.mov') or
    (AExt = '.mkv') or (AExt = '.webm');
end;

function SplitCriteriaKeywords(const ACriteria: string): TArray<string>;
const
  DELIMS: TSysCharSet = [' ', #9, ',', '/', '\', '-', '_', '.'];
var
  list: TList<string>;
  startPos, i: Integer;
  w: string;
begin
  list := TList<string>.Create;
  try
    { Scan once using RTL primitives shared by Delphi and FPC. WordCount
      and ExtractWord are not provided by Delphi's StrUtils unit. }
    i := 1;
    while i <= Length(ACriteria) do
    begin
      if CharInSet(ACriteria[i], DELIMS) then
      begin
        Inc(i);
        Continue;
      end;
      startPos := i;
      while i <= Length(ACriteria) do
      begin
        if CharInSet(ACriteria[i], DELIMS) then Break;
        Inc(i);
      end;
      w := Trim(Copy(ACriteria, startPos, i - startPos));
      if Length(w) >= 2 then
        list.Add(w);
    end;
    Result := list.ToArray;
  finally
    list.Free;
  end;
end;

{ Recurses into ADir (subfolders first, same traversal shape as
  UDAW.UI.MainForm.BrowserExpandNode), collecting full paths of audio files
  whose file name or containing folder name contains any of AKeywords
  (case-insensitive substring match - no fuzzy scoring, per the plan's
  "straightforward substring/keyword matching" scope). Empty AKeywords
  matches everything, so a blank criteria still returns something useful
  rather than nothing. Stops recursing once AResults reaches AMaxResults. }
procedure ScanFolderForAudio(const ADir: string; const AKeywords: TArray<string>;
  AResults: TStrings; AMaxResults: Integer);
var
  sr: TSearchRec;
  full, ext, folderName: string;
  matched: Boolean;
  i: Integer;
begin
  if AResults.Count >= AMaxResults then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, sr) = 0 then
  try
    repeat
      if AResults.Count >= AMaxResults then Break;
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      full := IncludeTrailingPathDelimiter(ADir) + sr.Name;
      if (sr.Attr and faDirectory) <> 0 then
        ScanFolderForAudio(full, AKeywords, AResults, AMaxResults)
      else
      begin
        ext := LowerCase(ExtractFileExt(sr.Name));
        if ToolIsAudioExt(ext) then
        begin
          folderName := ExtractFileName(ExcludeTrailingPathDelimiter(ADir));
          matched := Length(AKeywords) = 0;
          for i := 0 to High(AKeywords) do
            if ContainsText(sr.Name, AKeywords[i]) or ContainsText(folderName, AKeywords[i]) then
            begin
              matched := True;
              Break;
            end;
          if matched then
            AResults.Add(full);
        end;
      end;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

{ Content-sniffed header probe only (no decode) so FindSample stays fast even
  over a large library. Gives the AI the facts it needs to judge whether a
  candidate is actually usable for the part it is choosing it for - e.g. a
  0.05s file is a click/transient, not a bass note or pad, and a folder named
  "SFX" is a strong hint the file is a one-off effect rather than musical
  material - rather than picking on file/folder name alone and hoping. }
function ProbeAudioBasic(const APath: string; out ADurationSec: Double;
  out ASampleRate, AChannels: Integer): Boolean;
var
  wavInfo: TWavInfo;
  mp3Info: TMP3StreamInfo;
  flacInfo: TFLACStreamInfo;
  mp4Info: TMP4ProbeInfo;
begin
  Result := False;
  ADurationSec := 0;
  ASampleRate := 0;
  AChannels := 0;
  try
    if FileLooksLikeWav(APath) then
    begin
      wavInfo := ReadWavInfo(APath);
      ASampleRate := wavInfo.SampleRate;
      AChannels := wavInfo.Channels;
      if ASampleRate > 0 then ADurationSec := wavInfo.FrameCount / ASampleRate;
      Exit(True);
    end;
    if Mp3SniffFile(APath) and Mp3ProbeFile(APath, mp3Info) then
    begin
      ASampleRate := mp3Info.SampleRate;
      AChannels := mp3Info.Channels;
      if ASampleRate > 0 then ADurationSec := mp3Info.TotalSamples / ASampleRate;
      Exit(True);
    end;
    if FlacSniffFile(APath) and FlacProbeFile(APath, flacInfo) then
    begin
      ASampleRate := flacInfo.SampleRate;
      AChannels := flacInfo.Channels;
      if ASampleRate > 0 then ADurationSec := flacInfo.TotalSamples / ASampleRate;
      Exit(True);
    end;
    if Mp4SniffFile(APath) and Mp4ProbeFile(APath, mp4Info) and mp4Info.HasAudio then
    begin
      ASampleRate := mp4Info.SampleRate;
      AChannels := mp4Info.Channels;
      ADurationSec := mp4Info.DurationSeconds;
      Exit(True);
    end;
  except
    Exit(False);
  end;
end;

function TAIToolDispatcher.BuildFindSampleJSON(const ACriteria: string; AMaxResults: Integer): string;
var
  o, arr, item: TJSONValue;
  roots, keywords: TArray<string>;
  results: TStringList;
  i, cap: Integer;
  path, name, folder: string;
  durationSec: Double;
  sampleRate, channels: Integer;
begin
  o := JSONObject;
  try
    if not Assigned(FOnGetBrowserRoots) then
    begin
      o.AddPair('error', JSONString('no Browser folders are available to this session'));
      Exit(o.ToJSONString);
    end;
    roots := FOnGetBrowserRoots();
    if Length(roots) = 0 then
    begin
      o.AddPair('error', JSONString('no folders have been added to the Browser tab yet'));
      Exit(o.ToJSONString);
    end;
    cap := FIND_SAMPLE_MAX_RESULTS;
    if (AMaxResults > 0) and (AMaxResults < cap) then cap := AMaxResults;
    keywords := SplitCriteriaKeywords(ACriteria);
    results := TStringList.Create;
    try
      for i := 0 to High(roots) do
      begin
        if results.Count >= cap then Break;
        if DirectoryExists(roots[i]) then
          ScanFolderForAudio(roots[i], keywords, results, cap);
      end;
      arr := JSONArray;
      for i := 0 to results.Count - 1 do
      begin
        path := results[i];
        name := ExtractFileName(path);
        folder := ExtractFileName(ExcludeTrailingPathDelimiter(ExtractFileDir(path)));
        item := JSONObject;
        item.AddPair('path', JSONString(path));
        item.AddPair('name', JSONString(name));
        item.AddPair('folder', JSONString(folder));
        if ProbeAudioBasic(path, durationSec, sampleRate, channels) then
        begin
          item.AddPair('duration_sec', JSONNumber(RoundTo(durationSec, -3)));
          item.AddPair('sample_rate', JSONNumber(sampleRate));
          item.AddPair('channels', JSONNumber(channels));
        end;
        arr.AddItem(item);
      end;
      o.AddPair('count', JSONNumber(results.Count));
      o.AddPair('samples', arr);
    finally
      results.Free;
    end;
    Result := o.ToJSONString;
  finally
    o.Free;
  end;
end;

{ Safety boundary: the AI must never be able to make the app read an arbitrary
  filesystem path - only files inside a folder the user explicitly added to
  the Browser tab. }
function TAIToolDispatcher.ResolvePathUnderBrowserRoots(const APath: string;
  out AFullPath: string): Boolean;
var
  roots: TArray<string>;
  i: Integer;
  full, rootFull: string;
begin
  Result := False;
  AFullPath := '';
  if not Assigned(FOnGetBrowserRoots) then Exit;
  full := ExpandFileName(APath);
  roots := FOnGetBrowserRoots();
  for i := 0 to High(roots) do
  begin
    rootFull := IncludeTrailingPathDelimiter(ExpandFileName(roots[i]));
    if SameText(Copy(full, 1, Length(rootFull)), rootFull) then
    begin
      AFullPath := full;
      Exit(True);
    end;
  end;
end;

{ Same undo-safe "browser file -> timeline clip" path
  UDAW.UI.MainForm.TfrmMain.ImportBrowserFileToTimeline uses for drag-and-drop
  and the Browser tab's Import button: a fresh TMediaSource registered on the
  timeline (de-duplicated by path, same as every other importer), then one of
  the Phase 6/12/15/16 undo-aware import commands adds the clip through
  FCommands exactly like a mouse-driven edit. }
function TAIToolDispatcher.PerformAddSampleToTimeline(const ACall: TAIToolCall;
  out AResultText: string): Boolean;
var
  fullPath, ext: string;
  track: TTimelineTrack;
  info: TWavInfo;
  src: TMediaSource;
  addCmd: TAddTimelineClipCommand;
  flacCmd: TImportFlacCommand;
  mp3Cmd: TImportMp3Command;
  mp4Cmd: TImportMp4Command;
  extraTrack: TAddTimelineTrackCommand;
  streamNo: Integer;
  startSec: Double;
begin
  Result := False;
  if not ResolvePathUnderBrowserRoots(ACall.FilePath, fullPath) then
  begin
    AResultText := Format('"%s" is not inside a folder registered in the Browser', [ACall.FilePath]);
    Exit;
  end;
  if not FileExists(fullPath) then
  begin
    AResultText := Format('file not found: %s', [fullPath]);
    Exit;
  end;
  track := FindTrackByName(ACall.TrackName);
  if track = nil then
  begin
    AResultText := Format('no timeline track matches "%s" - use AddTrack first', [ACall.TrackName]);
    Exit;
  end;
  startSec := 0;
  if ACall.HasPositionSec then startSec := ACall.PositionSec;
  ext := LowerCase(ExtractFileExt(fullPath));
  try
    if ext = '.wav' then
    begin
      if not FileLooksLikeWav(fullPath) then
      begin AResultText := 'not a valid WAV file: ' + fullPath; Exit; end;
      info := ReadWavInfo(fullPath);
      src := FDoc.Timeline.AddSource(fullPath, info.SampleRate, info.Channels, info.FrameCount);
      addCmd := TAddTimelineClipCommand.Create(FDoc, track.Id, src.Id,
        ExtractFileName(fullPath), startSec, 0, info.FrameCount / info.SampleRate);
      if not FCommands.Perform(addCmd) then
      begin AResultText := 'could not add clip'; Exit; end;
    end
    else if ext = '.flac' then
    begin
      if not FlacSniffFile(fullPath) then
      begin AResultText := 'not a valid FLAC file: ' + fullPath; Exit; end;
      flacCmd := TImportFlacCommand.Create(FDoc, track.Id, fullPath, startSec, 0);
      if not FCommands.Perform(flacCmd) then
      begin AResultText := 'could not add clip'; Exit; end;
    end
    else if ext = '.mp3' then
    begin
      if not Mp3SniffFile(fullPath) then
      begin AResultText := 'not a valid MP3 file: ' + fullPath; Exit; end;
      mp3Cmd := TImportMp3Command.Create(FDoc, track.Id, fullPath, startSec, 0);
      if not FCommands.Perform(mp3Cmd) then
      begin AResultText := 'could not add clip'; Exit; end;
    end
    else if (ext = '.mp4') or (ext = '.m4a') or (ext = '.m4v') or (ext = '.mov') or
      (ext = '.mkv') or (ext = '.webm') then
    begin
      if not Mp4SniffFile(fullPath) then
      begin AResultText := 'not a valid MP4/M4A file: ' + fullPath; Exit; end;
      mp4Cmd := TImportMp4Command.Create(FDoc, track.Id, fullPath, startSec, 0);
      try
        mp4Cmd.Resolve;
      except
        mp4Cmd.Free;
        raise;
      end;
      { every further sound stream shows on a track of its own; the user removes
        what they do not want }
      for streamNo := 1 to mp4Cmd.AudioStreamCount - 1 do
      begin
        extraTrack := TAddTimelineTrackCommand.Create(FDoc, tkAudio,
          Format('%s (audio %d)', [track.Name, streamNo + 1]));
        if not FCommands.Perform(extraTrack) then
        begin
          mp4Cmd.Free;
          AResultText := 'could not add a track for an extra sound stream';
          Exit;
        end;
        mp4Cmd.SetStreamTrack(streamNo, extraTrack.CreatedId);
      end;
      if not FCommands.Perform(mp4Cmd) then
      begin AResultText := 'could not add clip'; Exit; end;
    end
    else
    begin
      AResultText := 'unsupported audio format: ' + ext;
      Exit;
    end;
  except
    on E: Exception do
    begin
      AResultText := 'import failed: ' + E.Message;
      Exit;
    end;
  end;
  AResultText := Format('added "%s" to track "%s" at %.3fs',
    [ExtractFileName(fullPath), track.Name, startSec]);
  Result := True;
end;

function TAIToolDispatcher.Execute(const ACall: TAIToolCall; out AResultText: string): Boolean;
var
  strip: TMixStrip;
  targetTrack: TTimelineTrack;
  newDb: Double;
  targetId: Integer;
  wantFlag: Boolean;
begin
  Result := False;
  AResultText := '';
  case ACall.Kind of
    atkGetProjectInfo:
      begin
        AResultText := BuildProjectInfoJSON;
        Result := True;
      end;
    atkGetTracks:
      begin
        AResultText := BuildTracksJSON;
        Result := True;
      end;
    atkGetTrackInfo:
      begin
        AResultText := BuildTrackInfoJSON(ACall.TrackName);
        Result := True;
      end;
    atkGetMixerState:
      begin
        AResultText := BuildMixerStateJSON;
        Result := True;
      end;
    atkGetSelection:
      begin
        AResultText := '{"note":"no selection API exposed to AI tools yet"}';
        Result := True;
      end;
    atkAnalyzeAudio:
      begin
        if Assigned(FOnAnalyzeAudio) then
          AResultText := FOnAnalyzeAudio(ACall.TrackName)
        else
          AResultText := '{"error":"no audio-rendering context available to analyze"}';
        Result := True;
      end;
    atkSuggestMix:
      begin
        if Assigned(FOnSuggestMix) then
          AResultText := FOnSuggestMix()
        else
          AResultText := '{"error":"mixing assistant not available"}';
        Result := True;
      end;
    atkGenerateMusic:
      begin
        if Assigned(FOnGenerateMusic) then
          AResultText := FOnGenerateMusic(ACall.Prompt)
        else
          AResultText := 'music generation is not wired up in this session';
        Result := Assigned(FOnGenerateMusic);
      end;
    atkExportProject:
      begin
        if Assigned(FOnExportProject) then
          AResultText := FOnExportProject()
        else
          AResultText := 'export is not wired up in this session';
        Result := Assigned(FOnExportProject);
      end;

    atkAddTrack:
      begin
        if FCommands.Perform(TAddTimelineTrackCommand.Create(FDoc, tkAudio, ACall.TrackName)) then
        begin
          AResultText := Format('added audio track "%s"', [ACall.TrackName]);
          Result := True;
        end
        else
          AResultText := 'nothing to do';
      end;

    atkSetTempo:
      begin
        if FCommands.Perform(TSetTempoCommand.Create(FDoc, ACall.TempoBpm)) then
        begin
          AResultText := Format('tempo set to %.2f BPM', [ACall.TempoBpm]);
          Result := True;
        end
        else
          AResultText := Format('tempo already %.2f BPM', [ACall.TempoBpm]);
      end;

    atkAddMarker:
      begin
        if FCommands.Perform(TAddTimelineMarkerCommand.Create(FDoc, ACall.MarkerName,
          IfThen(ACall.HasPositionSec, ACall.PositionSec, 0.0))) then
        begin
          AResultText := Format('added marker "%s"', [ACall.MarkerName]);
          Result := True;
        end
        else
          AResultText := 'could not add marker';
      end;

    atkMoveClip:
      begin
        targetId := 0;
        if ACall.HasTargetTrackName then
        begin
          targetTrack := FindTrackByName(ACall.TargetTrackName);
          if targetTrack = nil then
          begin
            AResultText := Format('no track matches "%s"', [ACall.TargetTrackName]);
            Exit(False);
          end;
          targetId := targetTrack.Id;
        end;
        if FCommands.Perform(TMoveTimelineClipCommand.Create(FDoc, ACall.ClipId,
          ACall.PositionSec, targetId)) then
        begin
          AResultText := Format('moved clip %d to %.3fs', [ACall.ClipId, ACall.PositionSec]);
          Result := True;
        end
        else
          AResultText := Format('no clip %d found (or already at that position)', [ACall.ClipId]);
      end;

    atkSetGain:
      begin
        strip := FindStripByName(ACall.TrackName);
        if strip = nil then
        begin
          AResultText := Format('no track/strip matches "%s"', [ACall.TrackName]);
          Exit(False);
        end;
        if ACall.HasAbsoluteDb then
          newDb := ACall.AbsoluteDb
        else
          newDb := strip.FaderDb + ACall.DeltaDb;
        if FCommands.Perform(TSetMixStripFloatCommand.Create(FDoc, strip.Id, mffFader, newDb)) then
        begin
          AResultText := Format('"%s" fader set to %.1f dB', [strip.Name, newDb]);
          Result := True;
        end
        else
          AResultText := Format('"%s" fader already %.1f dB', [strip.Name, newDb]);
      end;

    atkSetPan:
      begin
        strip := FindStripByName(ACall.TrackName);
        if strip = nil then
        begin
          AResultText := Format('no track/strip matches "%s"', [ACall.TrackName]);
          Exit(False);
        end;
        if FCommands.Perform(TSetMixStripFloatCommand.Create(FDoc, strip.Id, mffPan, ACall.PanValue)) then
        begin
          AResultText := Format('"%s" pan set to %.2f', [strip.Name, ACall.PanValue]);
          Result := True;
        end
        else
          AResultText := Format('"%s" pan already %.2f', [strip.Name, ACall.PanValue]);
      end;

    atkSetMute:
      begin
        strip := FindStripByName(ACall.TrackName);
        if strip = nil then
        begin
          AResultText := Format('no track/strip matches "%s"', [ACall.TrackName]);
          Exit(False);
        end;
        if ACall.HasEnabled then wantFlag := ACall.Enabled else wantFlag := True;
        if FCommands.Perform(TSetMixStripFlagCommand.Create(FDoc, strip.Id, mfgMute, wantFlag)) then
        begin
          AResultText := Format('"%s" mute set', [strip.Name]);
          Result := True;
        end
        else
          AResultText := Format('"%s" mute unchanged', [strip.Name]);
      end;

    atkSetSolo:
      begin
        strip := FindStripByName(ACall.TrackName);
        if strip = nil then
        begin
          AResultText := Format('no track/strip matches "%s"', [ACall.TrackName]);
          Exit(False);
        end;
        if ACall.HasEnabled then wantFlag := ACall.Enabled else wantFlag := True;
        if FCommands.Perform(TSetMixStripFlagCommand.Create(FDoc, strip.Id, mfgSolo, wantFlag)) then
        begin
          AResultText := Format('"%s" solo set', [strip.Name]);
          Result := True;
        end
        else
          AResultText := Format('"%s" solo unchanged', [strip.Name]);
      end;

    atkCreateAutomation:
      begin
        strip := FindStripByName(ACall.TrackName);
        if strip = nil then
        begin
          AResultText := Format('no track/strip matches "%s"', [ACall.TrackName]);
          Exit(False);
        end;
        { the automation engine has no curve-authoring API yet - the best this
          tool can do today is put the strip into write mode so subsequent
          fader/pan moves (human or further AI SetGain/SetPan calls) are
          captured, and say so plainly rather than pretending to draw a curve. }
        strip.AutomationMode := amWrite;
        FDoc.Touch;
        AResultText := Format(
          '"%s" automation mode set to Write (curve authoring is not yet implemented; ' +
          'further gain/pan changes on this strip will be the automation)', [strip.Name]);
        Result := True;
      end;

    atkFindSample:
      begin
        AResultText := BuildFindSampleJSON(ACall.Criteria,
          IfThen(ACall.HasMaxResults, ACall.MaxResults, 0));
        Result := True;
      end;

    atkAddSampleToTimeline:
      Result := PerformAddSampleToTimeline(ACall, AResultText);

    atkRenameTrack:
      begin
        targetTrack := FindTrackByName(ACall.TrackName);
        if targetTrack = nil then
          AResultText := Format('no track matches "%s"', [ACall.TrackName])
        else if FCommands.Perform(TRenameTimelineTrackCommand.Create(FDoc, targetTrack.Id, ACall.MarkerName)) then
        begin
          AResultText := Format('renamed track to "%s"', [ACall.MarkerName]);
          Result := True;
        end
        else
          AResultText := 'track name unchanged';
      end;

    atkSplitClip:
      if FCommands.Perform(TSplitTimelineClipCommand.Create(FDoc, ACall.ClipId, ACall.PositionSec)) then
      begin
        AResultText := Format('split clip %d at %.3fs', [ACall.ClipId, ACall.PositionSec]);
        Result := True;
      end
      else
        AResultText := Format('could not split clip %d at %.3fs (missing, or position outside the clip)',
          [ACall.ClipId, ACall.PositionSec]);

    atkDeleteClip:
      if FCommands.Perform(TRemoveTimelineClipCommand.Create(FDoc, ACall.ClipId)) then
      begin
        AResultText := Format('deleted clip %d', [ACall.ClipId]);
        Result := True;
      end
      else
        AResultText := Format('no clip %d found', [ACall.ClipId]);

    atkSetClipFade:
      begin
        Result := True;
        AResultText := '';
        if ACall.HasFadeInSec then
          if FCommands.Perform(TSetTimelineClipFadeCommand.Create(FDoc, ACall.ClipId, ceStart, ACall.FadeInSec)) then
            AResultText := AResultText + Format('fade-in %.3fs; ', [ACall.FadeInSec])
          else
            Result := False;
        if ACall.HasFadeOutSec then
          if FCommands.Perform(TSetTimelineClipFadeCommand.Create(FDoc, ACall.ClipId, ceEnd, ACall.FadeOutSec)) then
            AResultText := AResultText + Format('fade-out %.3fs; ', [ACall.FadeOutSec])
          else
            Result := False;
        if Result then
          AResultText := Format('clip %d: %s', [ACall.ClipId, AResultText])
        else
          AResultText := Format('could not set fade(s) on clip %d (missing, or unchanged)', [ACall.ClipId]);
      end;

    atkTransportPlay, atkTransportStop:
      if Assigned(FOnTransport) then
      begin
        AResultText := FOnTransport(IfThen(ACall.Kind = atkTransportPlay, 'play', 'stop'),
          ACall.HasFromBeginning and ACall.FromBeginning);
        Result := True;
      end
      else
        AResultText := 'transport control is not wired up in this session';

    atkGetAIProviders:
      begin
        AResultText := BuildAIProvidersJSON;
        Result := True;
      end;

    atkListCommands, atkRunCommand, atkSelectClips, atkSelectTrack,
    atkSetPlayhead, atkSetRange, atkClampClips:
      if Assigned(FOnUICommand) then
      begin
        AResultText := FOnUICommand(ACall);
        Result := Pos('"error"', AResultText) = 0;
      end
      else
        AResultText := '{"error":"application commands are not wired up in this session"}';
  end;
end;

end.
