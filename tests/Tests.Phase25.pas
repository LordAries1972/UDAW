unit Tests.Phase25;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 25 acceptance tests - the voice pipeline's command parser.

  UDAW.Voice.Capture (drains the audio engine's live capture ring) and
  UDAW.Voice.Recognition (shells out to System.Speech on Windows) both need
  a real device / real OS speech stack to exercise meaningfully, so those
  are left to interactive/manual testing - same rationale as every other
  hardware- or OS-facing unit in this suite. UDAW.Voice.Command has neither
  dependency by design (see its header comment) so it's fully covered here:
  exact-match recognition, case/punctuation/whitespace normalisation, and
  the "doesn't match anything" fall-through that the Voice panel uses to
  decide whether to run a built-in action or just forward the transcript to
  the AI chat. }

interface

procedure RegisterPhase25Tests;

implementation

uses
  SysUtils,
  UDAW.Testing,
  UDAW.Voice.Command;

const
  GRP = 'phase25.voice';

procedure Test_Parse_KnownCommands;
begin
  Check(ParseVoiceCommand('play') = vaPlay, 'play');
  Check(ParseVoiceCommand('Play') = vaPlay, 'play is case-insensitive');
  Check(ParseVoiceCommand('  play  ') = vaPlay, 'play trims whitespace');
  Check(ParseVoiceCommand('play.') = vaPlay, 'play tolerates trailing punctuation');
  Check(ParseVoiceCommand('stop') = vaStop, 'stop');
  Check(ParseVoiceCommand('pause') = vaStop, 'pause maps to stop (no separate pause transport state)');
  Check(ParseVoiceCommand('record') = vaRecord, 'record');
  Check(ParseVoiceCommand('undo') = vaUndo, 'undo');
  Check(ParseVoiceCommand('redo') = vaRedo, 'redo');
  Check(ParseVoiceCommand('save') = vaSaveProject, 'save');
  Check(ParseVoiceCommand('save project') = vaSaveProject, 'save project');
  Check(ParseVoiceCommand('new track') = vaNewAudioTrack, 'new track');
  Check(ParseVoiceCommand('add audio track') = vaNewAudioTrack, 'add audio track');
  Check(ParseVoiceCommand('clear chat') = vaClearChat, 'clear chat');
end;

procedure Test_Parse_UnrecognisedFallsThrough;
begin
  Check(ParseVoiceCommand('') = vaNone, 'empty string');
  Check(ParseVoiceCommand('what tempo is this project') = vaNone, 'a question falls through to chat');
  Check(ParseVoiceCommand('make the vocals louder') = vaNone, 'a request falls through to chat');
end;

procedure Test_ActionNames;
begin
  CheckEqualStr('Play', VoiceActionName(vaPlay), 'play name');
  CheckEqualStr('Stop', VoiceActionName(vaStop), 'stop name');
  CheckEqualStr('None', VoiceActionName(vaNone), 'none name');
end;

procedure RegisterPhase25Tests;
begin
  RegisterTest(GRP, 'Voice: known commands parse', Test_Parse_KnownCommands);
  RegisterTest(GRP, 'Voice: unrecognised text falls through to chat', Test_Parse_UnrecognisedFallsThrough);
  RegisterTest(GRP, 'Voice: action display names', Test_ActionNames);
end;

end.
