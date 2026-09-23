unit UDAW.Voice.Command;
{$I udaw.inc}

{ Phase 25 - the "act on it" tail end of the voice pipeline: a small, exact
  text-command grammar so a handful of transport/edit words spoken clearly
  ("play", "undo", "new track", ...) execute directly instead of round
  -tripping through a chat model. Anything that doesn't match is vaNone,
  and the caller (the Voice panel on the AI tab) falls back to treating the
  transcript as a normal AI chat prompt - so the pipeline is always useful
  even when the utterance isn't one of these fixed commands.

  Deliberately independent of UDAW.Voice.Capture / UDAW.Voice.Recognition
  (no audio, no COM, no process spawning) so it is plain, fast, and fully
  unit-testable on every platform. }

interface

type
  TVoiceAction = (
    vaNone,
    vaPlay,
    vaStop,
    vaRecord,
    vaUndo,
    vaRedo,
    vaSaveProject,
    vaNewAudioTrack,
    vaClearChat
  );

function ParseVoiceCommand(const AText: string): TVoiceAction;
function VoiceActionName(AAction: TVoiceAction): string;

implementation

uses
  SysUtils;

function Normalize(const AText: string): string;
var
  i: Integer;
  sb: string;
  c: Char;
begin
  sb := '';
  for i := 1 to Length(AText) do
  begin
    c := AText[i];
    if CharInSet(c, ['.', '!', '?', ',']) then Continue;
    sb := sb + c;
  end;
  Result := LowerCase(Trim(sb));
  while Pos('  ', Result) > 0 do
    Result := StringReplace(Result, '  ', ' ', [rfReplaceAll]);
end;

function ParseVoiceCommand(const AText: string): TVoiceAction;
var
  s: string;
begin
  Result := vaNone;
  s := Normalize(AText);
  if s = '' then Exit;

  if (s = 'play') or (s = 'start') or (s = 'start playback') or
     (s = 'play the project') or (s = 'play project') then
    Result := vaPlay
  else if (s = 'stop') or (s = 'pause') or (s = 'stop playback') then
    Result := vaStop
  else if (s = 'record') or (s = 'start recording') or (s = 'arm record') then
    Result := vaRecord
  else if s = 'undo' then
    Result := vaUndo
  else if s = 'redo' then
    Result := vaRedo
  else if (s = 'save') or (s = 'save project') then
    Result := vaSaveProject
  else if (s = 'new track') or (s = 'new audio track') or
          (s = 'add track') or (s = 'add audio track') then
    Result := vaNewAudioTrack
  else if (s = 'clear chat') or (s = 'clear the chat') then
    Result := vaClearChat;
end;

function VoiceActionName(AAction: TVoiceAction): string;
begin
  case AAction of
    vaPlay:          Result := 'Play';
    vaStop:          Result := 'Stop';
    vaRecord:        Result := 'Record';
    vaUndo:          Result := 'Undo';
    vaRedo:          Result := 'Redo';
    vaSaveProject:   Result := 'Save project';
    vaNewAudioTrack: Result := 'New audio track';
    vaClearChat:     Result := 'Clear chat';
  else
    Result := 'None';
  end;
end;

end.
