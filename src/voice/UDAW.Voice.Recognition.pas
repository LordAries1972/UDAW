unit UDAW.Voice.Recognition;
{$I udaw.inc}

{ Phase 25 - speech-to-text step of the voice pipeline.

  Windows-only for now (this project's currently verified target - see the
  Windows-first build focus recorded alongside the other phases). Shells
  out to a short generated PowerShell script that drives .NET's
  System.Speech.Recognition engine against a WAV file: SetInputToWaveFile
  + a free-dictation grammar + Recognize(). System.Speech ships with
  Windows/.NET itself, so this keeps the "no third-party library" policy
  for the actual recognition engine - the from-scratch policy is about
  UDAW's own audio/codec/DSP/UI code (see UDAW.Voice.Capture for the part
  that IS from-scratch: draining the engine's real capture ring to a WAV
  file), not about refusing to shell out to the OS's own speech stack the
  way UDAW.AI.HTTP reuses the RTL's HTTP client instead of vendoring one.

  A raw-COM SAPI implementation (mirroring UDAW.Audio.Backend.WASAPI's
  from-scratch COM interfaces) was considered and rejected for this first
  cut: SAPI's recognition events need either a hand-implemented
  IConnectionPoint event sink or several dozen vtable-order-sensitive
  method declarations on ISpRecoContext/ISpRecoGrammar/ISpRecoResult that
  cannot be verified without a live Windows COM run - a wrong vtable slot
  order fails silently at runtime, not at compile time. The process-based
  approach below has no such risk: only text crosses the boundary. }

interface

uses
  SysUtils;

{ Transcribes AWavPath (PCM WAV, any sample rate System.Speech accepts) to
  text. Returns False (with AText holding a diagnostic message, not
  raising) if speech recognition isn't available or didn't understand
  anything - "voice unavailable on this machine" / "didn't catch that" are
  expected, recoverable outcomes for the caller (the Voice panel) to
  display, not programming errors. }
function TranscribeWavFile(const AWavPath: string; out AText: string): Boolean;

{ True on Windows (System.Speech ships with every supported Windows/.NET
  install); False elsewhere, where TranscribeWavFile always fails. }
function VoiceRecognitionAvailable: Boolean;

implementation

{$IFDEF UDAW_WINDOWS}
uses
  Windows, Classes, StrUtils, UDAW.Paths;
{$ENDIF}

const
  SUBSYS = 'Voice.Recognition';

{$IFDEF UDAW_WINDOWS}

function VoiceRecognitionAvailable: Boolean;
begin
  Result := True;
end;

function RunAndWait(const ACommandLine: string; ATimeoutMs: Cardinal): Boolean;
var
  si: TStartupInfo;
  pi: TProcessInformation;
  cmdLine: string;
begin
  FillChar(si, SizeOf(si), 0);
  si.cb := SizeOf(si);
  si.dwFlags := STARTF_USESHOWWINDOW;
  si.wShowWindow := SW_HIDE;
  FillChar(pi, SizeOf(pi), 0);
  cmdLine := ACommandLine;
  UniqueString(cmdLine);

  Result := CreateProcess(nil, PChar(cmdLine), nil, nil, False,
    CREATE_NO_WINDOW, nil, nil, si, pi);
  if not Result then Exit;
  try
    if WaitForSingleObject(pi.hProcess, ATimeoutMs) = WAIT_TIMEOUT then
    begin
      TerminateProcess(pi.hProcess, 1);
      Result := False;
    end;
  finally
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
  end;
end;

function TranscribeWavFile(const AWavPath: string; out AText: string): Boolean;
const
  SCRIPT_LINES: array[0..10] of string = (
    'param([string]$WavPath, [string]$OutPath)',
    'try {',
    '  Add-Type -AssemblyName System.Speech',
    '  $reco = New-Object System.Speech.Recognition.SpeechRecognitionEngine',
    '  $reco.SetInputToWaveFile($WavPath)',
    '  $dict = New-Object System.Speech.Recognition.DictationGrammar',
    '  $reco.LoadGrammar($dict)',
    '  $result = $reco.Recognize()',
    '  if ($result -ne $null) { [System.IO.File]::WriteAllText($OutPath, $result.Text) }',
    '  else { [System.IO.File]::WriteAllText($OutPath, "") }',
    '} catch { [System.IO.File]::WriteAllText($OutPath, "ERROR: " + $_.Exception.Message) }'
  );
var
  scriptPath, outPath, cmdLine: string;
  script: TStringList;
  tag: string;
  i: Integer;
begin
  Result := False;
  AText := '';
  if not FileExists(AWavPath) then
  begin
    AText := 'wav file not found: ' + AWavPath;
    Exit;
  end;

  UDAW.Paths.EnsureDirs;
  tag := IntToHex(GetCurrentThreadId, 8) + IntToHex(Round(Now * 86400000), 12);
  scriptPath := UDAW.Paths.Paths.Temp + 'voice_reco_' + tag + '.ps1';
  outPath := UDAW.Paths.Paths.Temp + 'voice_reco_' + tag + '.txt';

  script := TStringList.Create;
  try
    for i := Low(SCRIPT_LINES) to High(SCRIPT_LINES) do
      script.Add(SCRIPT_LINES[i]);
    script.SaveToFile(scriptPath, TEncoding.UTF8);
  finally
    script.Free;
  end;

  try
    if FileExists(outPath) then SysUtils.DeleteFile(outPath);
    cmdLine := Format(
      'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%s" -WavPath "%s" -OutPath "%s"',
      [scriptPath, AWavPath, outPath]);

    if not RunAndWait(cmdLine, 20000) then
    begin
      AText := 'speech recognition process failed to start or timed out';
      Exit;
    end;

    if not FileExists(outPath) then
    begin
      AText := 'speech recognition produced no output';
      Exit;
    end;

    script := TStringList.Create;
    try
      script.LoadFromFile(outPath, TEncoding.UTF8);
      AText := Trim(script.Text);
    finally
      script.Free;
    end;
    if StartsText('ERROR:', AText) then Exit(False);
    if AText = '' then
    begin
      AText := '(no speech recognized)';
      Exit(False);
    end;
    Result := True;
  finally
    if FileExists(scriptPath) then SysUtils.DeleteFile(scriptPath);
    if FileExists(outPath) then SysUtils.DeleteFile(outPath);
  end;
end;

{$ELSE}

function VoiceRecognitionAvailable: Boolean;
begin
  Result := False;
end;

function TranscribeWavFile(const AWavPath: string; out AText: string): Boolean;
begin
  AText := 'voice recognition is only implemented on Windows (System.Speech) for now';
  Result := False;
end;

{$ENDIF}

end.
