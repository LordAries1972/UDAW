unit UDAW.Scripting.PyPlugin;
{$I udaw.inc}

{ Python plug-in host.

  A Python plug-in is a script that derives from udaw_plugin.Plugin (see Plugins\udaw_plugin.py,
  embedded in UDAW.Scripting.PluginSdk). Each running plug-in is its own Python process, so a
  faulty script can never take UDAW down; a Job object makes sure the processes die with UDAW.

  Conversation (little-endian frames: u32 type, u32 length, payload):
    UDAW -> Python   INIT json | PROCESS (u64 seq, u32 frames, u32 channels, planar float32)
                     PARAM json | EVENT json | PAINT json | TICK | GETSTATE | SETSTATE json |
                     RESET | SHUTDOWN
    Python -> UDAW   READY json | PROCESSED (same layout as PROCESS) | LOG json | UI json |
                     PAINT json | STATE json | ERROR json

  Audio is exchanged block by block. The audio thread sends a block and waits for the answer for
  at most a fraction of the block's duration; a late block is replaced by the dry signal (counted,
  shown in the editor). A plug-in that declares "buffered" gets its result one block late
  instead. While rendering offline (export) the host always waits for the answer, so a bounce is
  exact however slow the script is.

  Hosts are reference counted (Retain / Release) because the mixer node and an open editor
  window can both hold the same running plug-in. }

interface

uses
  Windows, SysUtils, Classes, SyncObjs, Generics.Collections, System.JSON, System.Math,
  System.NetEncoding, System.StrUtils;

const
  PYP_MIN_MAJOR = 3;
  PYP_MIN_MINOR = 14;

type
  TPyParamKind = (ppFloat, ppInt, ppBool, ppChoice);

  TPyParam = record
    Id, Name, UnitText, Group: string;
    Kind: TPyParamKind;
    Min, Max, DefaultValue, Value, Step: Double;
    Log: Boolean;
    Decimals: Integer;
    Choices: TArray<string>;
    { 0..1 position of Value / the value at a 0..1 position (logarithmic aware) }
    function ToNorm(AValue: Double): Double;
    function FromNorm(ANorm: Double): Double;
    function Clamp(AValue: Double): Double;
    function Display(AValue: Double): string;
  end;

  TPyIssue = record
    Severity: string;     // error | warning | info
    Line, Col: Integer;
    Msg: string;
  end;

  TPyMsgKind = (pmLog, pmUi, pmPaint, pmError);

  TPyMsg = record
    Kind: TPyMsgKind;
    Text: string;         // log line / JSON / error text
  end;

  { one MIDI message the script sent with send_midi (raw status byte + two data bytes) }
  TPyMidiOut = record
    Status, Data1, Data2: Byte;
  end;

  TPyPluginHost = class
  private
    FRefs: Integer;
    FProc, FThread, FStdinW, FStdoutR, FStderrR: THandle;
    FReader, FErrReader: TThread;
    FWriteLock: TCriticalSection;
    FDataLock: TCriticalSection;
    FReadyEvt, FReplyEvt, FStateEvt: TEvent;
    FReady, FDead, FStopping: Boolean;
    FStartError, FLastError, FStateJson: string;
    FName, FVendor, FAuthor, FVersion, FDescription, FPythonVersion, FUiJson: string;
    FBuffered: Boolean;
    FParams: TArray<TPyParam>;
    FSampleRate, FChannels, FMaxFrames: Integer;
    { audio exchange }
    FSendBuf: TBytes;
    FSeq: UInt64;
    FSlotSeq: array[0..3] of Int64;
    FSlotFrames: array[0..3] of Integer;
    FSlotData: array[0..3] of TArray<Single>;
    FBlocks, FLate, FDropped: Integer;
    FHighReply: Int64;
    FAudioActive: Boolean;
    { messages for an attached editor }
    FInbox: TList<TPyMsg>;
    FMidiOut: TList<TPyMidiOut>;   // script -> world, guarded by FDataLock, newest kept when full
    FAttached: Integer;
    FLogRing: TStringList;
    procedure ReaderLoop;
    procedure StderrLoop;
    procedure HandleFrame(AType: Cardinal; const APayload: TBytes);
    procedure HandleReady(const AJson: string);
    procedure HandleUi(const AJson: string);
    procedure Enqueue(AKind: TPyMsgKind; const AText: string);
    procedure AddLog(const ALine: string);
    function WriteFrame(AType: Cardinal; const APayload: TBytes): Boolean;
    function WriteJson(AType: Cardinal; AObj: TJSONObject): Boolean;
    function ParamIndex(const AId: string): Integer;
    function GetBlocksLatePercent: Double;
    procedure KillProcess;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Retain;
    { drops one reference; the last one shuts the process down and frees the host }
    procedure Release;

    { Starts the interpreter, loads the script and waits for it to describe itself. }
    function Start(const ASource, AFileName, AScriptDir, AValuesJson, AStateJson: string;
      ASampleRate, AChannels, AMaxFrames: Integer; out AError: string): Boolean;
    procedure Stop;

    { ---- audio (called from the mixer's thread) ---- }
    function ProcessBlock(const AIn, AOut: array of System.PSingle; AFrames: Integer): Boolean;
    procedure ResetDsp;

    { ---- parameters ---- }
    function ParamCount: Integer;
    function GetParam(AIndex: Integer): TPyParam;
    function ParamValue(const AId: string; ADefault: Double = 0): Double;
    procedure SetParam(const AId: string; AValue: Double);
    { automation / modulation: ANorm is 0..1 across the parameter's range }
    procedure SetParamNorm(AIndex: Integer; ANorm: Double);
    function ParamNames: string;

    { ---- window plumbing ---- }
    procedure SendEvent(const AControl, AEvent: string; const AValue: string = '';
      X: Integer = 0; Y: Integer = 0; AButton: Integer = 0);
    procedure RequestPaint(const AControl: string; AWidth, AHeight: Integer);
    procedure Tick;
    { a MIDI message for the script's on_midi (any thread) }
    procedure SendMidi(AStatus, AData1, AData2: Byte);
    { Current parameter values + the script's own saved data, as JSON; '' if the plug-in is gone. }
    function CaptureState(ATimeoutMs: Integer = 3000): string;
    procedure RestoreState(const AStateJson: string);
    procedure AttachUi;
    procedure DetachUi;
    { True while an editor window shows this plug-in }
    function UiAttached: Boolean;
    { Moves the queued messages out. }
    procedure TakeMessages(AInto: TList<TPyMsg>);
    { Moves the MIDI the script has sent (send_midi) since the last call into AInto, in order. Works
      with or without a window attached; unread output is capped, oldest dropped. }
    procedure TakeMidiOut(AInto: TList<TPyMidiOut>);
    function LogText: string;

    { Offline rendering (export) runs on its own thread: between Begin and End on that thread the
      host waits for every block, so a bounce is exact however slow the script is. }
    class procedure BeginOffline; static;
    class procedure EndOffline; static;

    property Ready: Boolean read FReady;
    property Dead: Boolean read FDead;
    property StartError: string read FStartError;
    property LastError: string read FLastError write FLastError;
    property Name: string read FName;
    property Vendor: string read FVendor;
    property Author: string read FAuthor;
    property Version: string read FVersion;
    property Description: string read FDescription;
    property PythonVersion: string read FPythonVersion;
    property Buffered: Boolean read FBuffered;
    property UiJson: string read FUiJson;
    property SampleRate: Integer read FSampleRate;
    property Channels: Integer read FChannels;
    property MaxFrames: Integer read FMaxFrames;
    property AudioActive: Boolean read FAudioActive write FAudioActive;
    property LateBlocks: Integer read FLate;
    property DroppedBlocks: Integer read FDropped;
    property BlocksProcessed: Integer read FBlocks;
    property LatePercent: Double read GetBlocksLatePercent;
  end;

  { Running plug-ins by instance id, so a window can attach to the one the mixer is playing. }
  TPyLiveRegistry = class
  private
    FLock: TCriticalSection;
    FMap: TDictionary<string, TPyPluginHost>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Register(const AId: string; AHost: TPyPluginHost);
    procedure Unregister(const AId: string; AHost: TPyPluginHost);
    { a retained reference, or nil; the caller must Release it }
    function Acquire(const AId: string): TPyPluginHost;
    { MIDI for plug-ins running on mixer strips that have no editor window open (an open window
      owns its plug-in's MIDI devices): collects what they sent with send_midi / hands them a
      message for on_midi }
    procedure DrainMidiOut(AInto: TList<TPyMidiOut>);
    procedure BroadcastMidi(AStatus, AData1, AData2: Byte);
  end;

var
  { folder holding udaw_plugin.py (and the user's plug-ins); set by the application }
  PyPluginsFolder: string;
  { work folder for the checker's copy of unsaved text (the cache folder); set by the application }
  PyScratchFolder: string;
  { where plug-ins save and load their presets (Settings > Working Directories > Presets, or a
    Presets folder inside the plug-ins folder); set by the application }
  PyPresetsFolder: string;

function PyLive: TPyLiveRegistry;
{ the newest Python >= 3.14, or '' (AMessage says what was found instead) }
function PyFindInterpreter(out AMessage: string): string;
{ writes udaw_plugin.py (always current) and the bundled plug-ins (when missing) into AFolder }
procedure PyEnsureSdk(const AFolder: string);
function PyEncode(const AText: string): string;
{ value of AKey in a "key=value;key=value" insert parameter string ('' if absent) }
function PyParamGet(const AParams, AKey: string): string;
{ The script of a Python insert. The insert points at the script file (path=); the text is read from there
  every time, so edits to the file are picked up. (Projects from before this stored the text itself in src=,
  which is still honoured.) AError says where it looked when the file is gone. }
function PyInsertSource(const AParams: string; out ASource, AFileName, AScriptDir, AError: string): Boolean;
{ changes when the script file changes (empty if it does not exist) }
function PyScriptStamp(const APath: string): string;
{ the same string with AKey set to AValue (added when missing) }
function PyParamSet(const AParams, AKey, AValue: string): string;
function PyDecode(const AB64: string): string;
{ Runs the script's checks (syntax, load, parameters, window, a test signal); ACodeFile is the file
  validated - the text is written there first so unsaved edits are checked too. }
function PyValidate(const ASource, ACodeFile: string; out AIssues: TArray<TPyIssue>;
  out AError: string; const APump: TProc = nil): Boolean;
function PyTemplateSource: string;

implementation

uses
  System.IOUtils, UDAW.Scripting.PluginSdk;

const
  MSG_INIT = 1; MSG_PROCESS = 2; MSG_PARAM = 3; MSG_SHUTDOWN = 4; MSG_EVENT = 5; MSG_PAINT = 6;
  MSG_GETSTATE = 7; MSG_SETSTATE = 8; MSG_RESET = 9; MSG_TICK = 10; MSG_MIDI = 11;
  RSP_READY = 101; RSP_PROCESSED = 102; RSP_LOG = 103; RSP_UI = 104; RSP_PAINT = 105;
  RSP_STATE = 106; RSP_ERROR = 107; RSP_MIDI = 108;
  MIDI_OUT_CAP = 4096;

  MAX_FRAME_BYTES = 64 * 1024 * 1024;
  LOG_RING_LINES = 300;
  JOB_KILL_ON_CLOSE = $2000;

type
  TJobBasic = record
    PerProcessUserTimeLimit, PerJobUserTimeLimit: Int64;
    LimitFlags: DWORD;
    MinimumWorkingSetSize, MaximumWorkingSetSize: NativeUInt;
    ActiveProcessLimit: DWORD;
    Affinity: NativeUInt;
    PriorityClass, SchedulingClass: DWORD;
  end;

  TJobExtended = record
    Basic: TJobBasic;
    IoCounters: array[0..5] of UInt64;
    ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed: NativeUInt;
  end;

function PyCreateJob(AAttrs: Pointer; AName: PWideChar): THandle; stdcall;
  external kernel32 name 'CreateJobObjectW';
function PySetJobInfo(AJob: THandle; AClass: Integer; AInfo: Pointer; ALen: DWORD): BOOL; stdcall;
  external kernel32 name 'SetInformationJobObject';
function PyAssignJob(AJob, AProcess: THandle): BOOL; stdcall;
  external kernel32 name 'AssignProcessToJobObject';

threadvar
  GOfflineDepth: Integer;

var
  GJob: THandle;
  GLive: TPyLiveRegistry;
  GPython: string;

type
  { reads one pipe on its own thread }
  TPyPipeThread = class(TThread)
  private
    FHost: TPyPluginHost;
    FErr: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AHost: TPyPluginHost; AStderr: Boolean);
  end;

constructor TPyPipeThread.Create(AHost: TPyPluginHost; AStderr: Boolean);
begin
  FHost := AHost;
  FErr := AStderr;
  inherited Create(False);
end;

procedure TPyPipeThread.Execute;
begin
  if FErr then FHost.StderrLoop else FHost.ReaderLoop;
end;

{ ---------------- helpers ---------------- }

function PyEncode(const AText: string): string;
begin
  Result := TNetEncoding.Base64.EncodeBytesToString(TEncoding.UTF8.GetBytes(AText));
  { the mixer's "key=value;" text format must never see line breaks }
  Result := StringReplace(StringReplace(Result, #13, '', [rfReplaceAll]), #10, '', [rfReplaceAll]);
end;

function PyDecode(const AB64: string): string;
begin
  if AB64 = '' then Exit('');
  try
    Result := TEncoding.UTF8.GetString(TNetEncoding.Base64.DecodeStringToBytes(AB64));
  except
    Result := '';
  end;
end;

function PyParamGet(const AParams, AKey: string): string;
var
  part: string;
  eq: Integer;
begin
  Result := '';
  for part in AParams.Split([';']) do
  begin
    eq := Pos('=', part);
    if (eq > 0) and SameText(Copy(part, 1, eq - 1), AKey) then Exit(Copy(part, eq + 1, MaxInt));
  end;
end;

function PyScriptStamp(const APath: string): string;
var
  age: TDateTime;
begin
  Result := '';
  if (APath <> '') and FileAge(APath, age) then Result := FormatDateTime('yyyymmddhhnnsszzz', age);
end;

function PyInsertSource(const AParams: string; out ASource, AFileName, AScriptDir, AError: string): Boolean;
var
  path: string;
begin
  Result := False;
  ASource := '';
  AScriptDir := '';
  AError := '';
  path := PyDecode(PyParamGet(AParams, 'path'));
  AFileName := PyDecode(PyParamGet(AParams, 'file'));
  if path <> '' then
  begin
    if not FileExists(path) then
    begin
      AError := 'The plug-in script was not found:'#13#10 + path + #13#10#13#10 +
        'Put the file back, or add the plug-in again from where it is now.';
      Exit;
    end;
    try
      ASource := TFile.ReadAllText(path, TEncoding.UTF8);
    except
      on E: Exception do
      begin
        AError := 'The plug-in script could not be read:'#13#10 + path + #13#10 + E.Message;
        Exit;
      end;
    end;
    AFileName := ExtractFileName(path);
    AScriptDir := ExtractFilePath(path);
  end
  else
    ASource := PyDecode(PyParamGet(AParams, 'src'));
  if AFileName = '' then AFileName := 'plugin.py';
  if ASource = '' then
  begin
    AError := 'This insert has no plug-in script.';
    Exit;
  end;
  Result := True;
end;

function PyParamSet(const AParams, AKey, AValue: string): string;
var
  part: string;
  eq: Integer;
  found: Boolean;
begin
  Result := '';
  found := False;
  for part in AParams.Split([';']) do
  begin
    if part = '' then Continue;
    eq := Pos('=', part);
    if Result <> '' then Result := Result + ';';
    if (eq > 0) and SameText(Copy(part, 1, eq - 1), AKey) then
    begin
      Result := Result + AKey + '=' + AValue;
      found := True;
    end
    else
      Result := Result + part;
  end;
  if not found then
  begin
    if Result <> '' then Result := Result + ';';
    Result := Result + AKey + '=' + AValue;
  end;
end;

function PyLive: TPyLiveRegistry;
begin
  if GLive = nil then GLive := TPyLiveRegistry.Create;
  Result := GLive;
end;

function ReadExact(AHandle: THandle; var ABuf; ACount: Integer): Boolean;
var
  p: PByte;
  got: DWORD;
begin
  p := @ABuf;
  while ACount > 0 do
  begin
    if not ReadFile(AHandle, p^, ACount, got, nil) or (got = 0) then Exit(False);
    Inc(p, got);
    Dec(ACount, Integer(got));
  end;
  Result := True;
end;

{ Starts python.exe with the three std handles redirected; AInheritIn/Out/Err are the child's ends. }
function SpawnPython(const AExe, AArgs, ADir: string; AIn, AOut, AErr: THandle;
  out AProc, AThread: THandle; out AError: string): Boolean;
var
  si: TStartupInfo;
  pi: TProcessInformation;
  cmd, env: string;
  envBlock: TBytes;
  blk: PChar;
  q: PChar;
  dirPtr: PChar;
begin
  Result := False;
  if ADir = '' then dirPtr := nil else dirPtr := PChar(ADir);
  env := '';
  blk := GetEnvironmentStrings;
  q := blk;
  while q^ <> #0 do
  begin
    env := env + q + #0;
    Inc(q, StrLen(q) + 1);
  end;
  FreeEnvironmentStrings(blk);
  env := env + 'PYTHONUNBUFFERED=1'#0'PYTHONIOENCODING=utf-8'#0'PYTHONDONTWRITEBYTECODE=1'#0#0;
  SetLength(envBlock, Length(env) * SizeOf(Char));
  Move(env[1], envBlock[0], Length(envBlock));

  FillChar(si, SizeOf(si), 0);
  si.cb := SizeOf(si);
  si.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
  si.wShowWindow := SW_HIDE;
  si.hStdInput := AIn;
  si.hStdOutput := AOut;
  si.hStdError := AErr;
  FillChar(pi, SizeOf(pi), 0);
  cmd := '"' + AExe + '" ' + AArgs;
  UniqueString(cmd);
  if not CreateProcess(nil, PChar(cmd), nil, nil, True,
       CREATE_NO_WINDOW or CREATE_UNICODE_ENVIRONMENT or CREATE_SUSPENDED, @envBlock[0],
       dirPtr, si, pi) then
  begin
    AError := 'Could not start Python: ' + SysErrorMessage(GetLastError);
    Exit;
  end;
  { children die with UDAW, however UDAW ends }
  if GJob = 0 then
  begin
    GJob := PyCreateJob(nil, nil);
    if GJob <> 0 then
    begin
      var info: TJobExtended;
      FillChar(info, SizeOf(info), 0);
      info.Basic.LimitFlags := JOB_KILL_ON_CLOSE;
      PySetJobInfo(GJob, 9, @info, SizeOf(info));
    end;
  end;
  if GJob <> 0 then PyAssignJob(GJob, pi.hProcess);
  ResumeThread(pi.hThread);
  AProc := pi.hProcess;
  AThread := pi.hThread;
  Result := True;
end;

{ Runs AExe with AArgs to completion and returns what it printed. }
function RunCapture(const AExe, AArgs, ADir: string; ATimeoutMs: Integer; out AOutput: string;
  out AExit: Integer; const APump: TProc): Boolean;
var
  sa: TSecurityAttributes;
  rd, wr, nul: THandle;
  proc, thr: THandle;
  err: string;
  raw: AnsiString;
  chunk: TBytes;
  avail, got: DWORD;
  started: UInt64;
  code: DWORD;
  acc: TBytesStream;

  procedure Drain;
  begin
    while PeekNamedPipe(rd, nil, 0, nil, @avail, nil) and (avail > 0) do
    begin
      SetLength(chunk, avail);
      if not ReadFile(rd, chunk[0], avail, got, nil) or (got = 0) then Break;
      acc.Write(chunk[0], got);
    end;
  end;

begin
  Result := False;
  AOutput := '';
  AExit := -1;
  FillChar(sa, SizeOf(sa), 0);
  sa.nLength := SizeOf(sa);
  sa.bInheritHandle := True;
  if not CreatePipe(rd, wr, @sa, 0) then Exit;
  SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);
  nul := CreateFile('NUL', GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, @sa, OPEN_EXISTING, 0, 0);
  acc := TBytesStream.Create;
  try
    if not SpawnPython(AExe, AArgs, ADir, nul, wr, wr, proc, thr, err) then
    begin
      AOutput := err;
      Exit;
    end;
    CloseHandle(wr);
    wr := 0;
    started := GetTickCount64;
    while WaitForSingleObject(proc, 20) = WAIT_TIMEOUT do
    begin
      Drain;
      if Assigned(APump) then APump();
      if GetTickCount64 - started > UInt64(ATimeoutMs) then
      begin
        TerminateProcess(proc, 1);
        AOutput := 'The check did not finish within ' + IntToStr(ATimeoutMs div 1000) +
          ' s - does the script loop forever while loading?';
        CloseHandle(proc);
        CloseHandle(thr);
        Exit;
      end;
    end;
    Drain;
    code := 0;
    GetExitCodeProcess(proc, code);
    AExit := Integer(code);
    CloseHandle(proc);
    CloseHandle(thr);
    SetString(raw, PAnsiChar(acc.Bytes), acc.Size);
    AOutput := UTF8ToString(raw);
    Result := True;
  finally
    acc.Free;
    if wr <> 0 then CloseHandle(wr);
    CloseHandle(rd);
    if nul <> INVALID_HANDLE_VALUE then CloseHandle(nul);
  end;
end;

{ ---------------- interpreter discovery ---------------- }

function PyVersionOfFolder(const AFolder: string): Integer;
var
  digits: string;
  c: Char;
begin
  { "Python314" / "Python313-64" -> 314 }
  digits := '';
  for c in Copy(AFolder, 7, MaxInt) do
    if CharInSet(c, ['0'..'9']) then digits := digits + c else Break;
  Result := StrToIntDef(digits, 0);
end;

function PyVersionOfExe(const AExe: string): Integer;
var
  outp: string;
  code: Integer;
begin
  Result := 0;
  if RunCapture(AExe, '-c "import sys;print(sys.version_info[0]*100+sys.version_info[1])"', '', 8000,
       outp, code, nil) and (code = 0) then
    Result := StrToIntDef(Trim(outp), 0);
end;

function PyFindInterpreter(out AMessage: string): string;
var
  best, v, bestV: Integer;
  roots: TArray<string>;
  root, d, p, forced: string;
  sr: TSearchRec;
  highest: Integer;
begin
  AMessage := '';
  if (GPython <> '') and FileExists(GPython) then Exit(GPython);
  Result := '';
  best := 0;
  bestV := PYP_MIN_MAJOR * 100 + PYP_MIN_MINOR;
  highest := 0;

  forced := GetEnvironmentVariable('UDAW_PYTHON');
  if (forced <> '') and FileExists(forced) then
  begin
    v := PyVersionOfExe(forced);
    if v >= bestV then
    begin
      GPython := forced;
      Exit(forced);
    end;
    highest := v;
  end;

  roots := TArray<string>.Create(
    IncludeTrailingPathDelimiter(GetEnvironmentVariable('LOCALAPPDATA')) + 'Programs\Python\',
    IncludeTrailingPathDelimiter(GetEnvironmentVariable('ProgramFiles')) + 'Python\',
    'C:\');
  for root in roots do
  begin
    if FindFirst(root + 'Python3*', faDirectory, sr) = 0 then
    try
      repeat
        p := root + sr.Name + '\python.exe';
        if FileExists(p) then
        begin
          v := PyVersionOfFolder(sr.Name);
          if v > highest then highest := v;
          if v > best then
          begin
            best := v;
            Result := p;
          end;
        end;
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
  end;
  { PATH last (skipping the Store stub) - its version has to be asked }
  if best < bestV then
    for d in GetEnvironmentVariable('PATH').Split([';']) do
      if d <> '' then
      begin
        p := IncludeTrailingPathDelimiter(d) + 'python.exe';
        if FileExists(p) and (Pos('\WindowsApps\', p) = 0) then
        begin
          v := PyVersionOfExe(p);
          if v > highest then highest := v;
          if v > best then
          begin
            best := v;
            Result := p;
          end;
        end;
      end;
  if best >= bestV then
    GPython := Result
  else
  begin
    Result := '';
    if highest > 0 then
      AMessage := Format('Python %d.%d was found, but UDAW plug-ins need Python %d.%d or newer. ' +
        'Install a current Python from python.org.',
        [highest div 100, highest mod 100, PYP_MIN_MAJOR, PYP_MIN_MINOR])
    else
      AMessage := Format('Python %d.%d or newer was not found. Install it from python.org and ' +
        'tick "Add python.exe to PATH".', [PYP_MIN_MAJOR, PYP_MIN_MINOR]);
  end;
end;

procedure PyEnsureSdk(const AFolder: string);
var
  sl: TStringList;
  f: string;
  cur: TStringList;

  procedure WriteIf(const AName, AText: string; AAlways: Boolean);
  begin
    f := IncludeTrailingPathDelimiter(AFolder) + AName;
    if not AAlways and FileExists(f) then Exit;
    if AAlways and FileExists(f) then
    begin
      cur := TStringList.Create;
      try
        cur.LoadFromFile(f, TEncoding.UTF8);
        if cur.Text = AText then Exit;
      finally
        cur.Free;
      end;
    end;
    sl := TStringList.Create;
    try
      sl.Text := AText;
      sl.SaveToFile(f, TEncoding.UTF8);
    finally
      sl.Free;
    end;
  end;

begin
  if AFolder = '' then Exit;
  ForceDirectories(AFolder);
  try
    WriteIf('udaw_plugin.py', PluginSdkSource, True);
    WriteIf('Guitar_Overdrive_Distortion.py', PluginExampleSource, False);
    WriteIf('Vocoder.py', PluginVocoderSource, False);
    WriteIf('Reverberator_Chorus.py', PluginReverbSource, False);
    WriteIf('Virtual_Guitar_Rig.py', PluginRigSource, False);
    WriteIf('Stutter_Edit.py', PluginStutterSource, False);
    WriteIf('Tuner.py', PluginTunerSource, False);
  except
    { read-only folder: the existing copy is used }
  end;
end;

{ the editor's "New" plug-in: scripts/plugin_template.py, embedded by scripts/gen-plugin-sdk.py (it carries
  the tab row, the preset controls and the MIDI tab every plug-in is meant to have) }
function PyTemplateSource: string;
begin
  Result := StringReplace(PluginTemplateSource, #10, #13#10, [rfReplaceAll]);
end;

function PyValidate(const ASource, ACodeFile: string; out AIssues: TArray<TPyIssue>;
  out AError: string; const APump: TProc): Boolean;
var
  exe, outp, msg: string;
  code, i: Integer;
  sl: TStringList;
  v: TJSONValue;
  arr: TJSONArray;
  o: TJSONObject;
begin
  Result := False;
  AError := '';
  SetLength(AIssues, 0);
  exe := PyFindInterpreter(msg);
  if exe = '' then
  begin
    AError := msg;
    Exit;
  end;
  PyEnsureSdk(PyPluginsFolder);
  ForceDirectories(ExtractFilePath(ACodeFile));
  sl := TStringList.Create;
  try
    sl.Text := ASource;
    sl.SaveToFile(ACodeFile, TEncoding.UTF8);
  finally
    sl.Free;
  end;
  if not RunCapture(exe, '-X utf8 -B "' + IncludeTrailingPathDelimiter(PyPluginsFolder) +
       'udaw_plugin.py" --validate "' + ACodeFile + '"', PyPluginsFolder, 60000, outp, code, APump) then
  begin
    AError := outp;
    Exit;
  end;
  v := TJSONObject.ParseJSONValue(Trim(outp));
  try
    if not (v is TJSONArray) then
    begin
      AError := 'The checker did not answer:'#13#10 + Trim(outp);
      Exit;
    end;
    arr := TJSONArray(v);
    SetLength(AIssues, arr.Count);
    for i := 0 to arr.Count - 1 do
    begin
      o := arr.Items[i] as TJSONObject;
      AIssues[i].Severity := o.GetValue<string>('severity', 'info');
      AIssues[i].Line := o.GetValue<Integer>('line', 0);
      AIssues[i].Col := o.GetValue<Integer>('col', 0);
      AIssues[i].Msg := o.GetValue<string>('message', '');
    end;
    Result := True;
  finally
    v.Free;
  end;
end;

{ ---------------- TPyParam ---------------- }

function TPyParam.Clamp(AValue: Double): Double;
begin
  if IsNan(AValue) then AValue := DefaultValue;
  Result := EnsureRange(AValue, Min, Max);
  if Kind in [ppInt, ppBool, ppChoice] then
    Result := Round(Result)
  else if Step > 0 then
    Result := Min + Round((Result - Min) / Step) * Step;
end;

function TPyParam.ToNorm(AValue: Double): Double;
begin
  if Max <= Min then Exit(0);
  if Log and (Min > 0) and (AValue > 0) then
    Result := Ln(AValue / Min) / Ln(Max / Min)
  else
    Result := (AValue - Min) / (Max - Min);
  Result := EnsureRange(Result, 0, 1);
end;

function TPyParam.FromNorm(ANorm: Double): Double;
begin
  ANorm := EnsureRange(ANorm, 0, 1);
  if Log and (Min > 0) then
    Result := Min * Power(Max / Min, ANorm)
  else
    Result := Min + ANorm * (Max - Min);
  Result := Clamp(Result);
end;

function TPyParam.Display(AValue: Double): string;
var
  idx: Integer;
begin
  case Kind of
    ppBool: if AValue >= 0.5 then Result := 'On' else Result := 'Off';
    ppChoice:
      begin
        idx := Round(AValue);
        if (idx >= 0) and (idx < Length(Choices)) then Result := Choices[idx] else Result := IntToStr(idx);
      end;
  else
    Result := FloatToStrF(AValue, ffFixed, 15, Decimals, TFormatSettings.Invariant);
    if UnitText <> '' then Result := Result + ' ' + UnitText;
  end;
end;

{ ---------------- TPyPluginHost ---------------- }

constructor TPyPluginHost.Create;
var
  i: Integer;
begin
  inherited Create;
  FRefs := 1;
  FWriteLock := TCriticalSection.Create;
  FDataLock := TCriticalSection.Create;
  FReadyEvt := TEvent.Create(nil, True, False, '');
  FReplyEvt := TEvent.Create(nil, True, False, '');
  FStateEvt := TEvent.Create(nil, True, False, '');
  FInbox := TList<TPyMsg>.Create;
  FMidiOut := TList<TPyMidiOut>.Create;
  FLogRing := TStringList.Create;
  FHighReply := -1;
  for i := 0 to 3 do FSlotSeq[i] := -1;
end;

destructor TPyPluginHost.Destroy;
begin
  Stop;
  FInbox.Free;
  FMidiOut.Free;
  FLogRing.Free;
  FStateEvt.Free;
  FReplyEvt.Free;
  FReadyEvt.Free;
  FDataLock.Free;
  FWriteLock.Free;
  inherited Destroy;
end;

procedure TPyPluginHost.Retain;
begin
  TInterlocked.Increment(FRefs);
end;

procedure TPyPluginHost.Release;
begin
  if TInterlocked.Decrement(FRefs) = 0 then Free;
end;

class procedure TPyPluginHost.BeginOffline;
begin
  Inc(GOfflineDepth);
end;

class procedure TPyPluginHost.EndOffline;
begin
  if GOfflineDepth > 0 then Dec(GOfflineDepth);
end;

function TPyPluginHost.GetBlocksLatePercent: Double;
begin
  if FBlocks <= 0 then Result := 0 else Result := 100.0 * FLate / FBlocks;
end;

procedure TPyPluginHost.AddLog(const ALine: string);
begin
  FDataLock.Enter;
  try
    FLogRing.Add(ALine);
    while FLogRing.Count > LOG_RING_LINES do FLogRing.Delete(0);
  finally
    FDataLock.Leave;
  end;
end;

function TPyPluginHost.LogText: string;
begin
  FDataLock.Enter;
  try
    Result := FLogRing.Text;
  finally
    FDataLock.Leave;
  end;
end;

procedure TPyPluginHost.Enqueue(AKind: TPyMsgKind; const AText: string);
var
  m: TPyMsg;
begin
  m.Kind := AKind;
  m.Text := AText;
  FDataLock.Enter;
  try
    if (AKind in [pmUi, pmPaint]) and (FAttached = 0) then Exit;
    if FInbox.Count > 2000 then FInbox.Delete(0);
    FInbox.Add(m);
  finally
    FDataLock.Leave;
  end;
end;

procedure TPyPluginHost.AttachUi;
begin
  FDataLock.Enter;
  try
    Inc(FAttached);
  finally
    FDataLock.Leave;
  end;
end;

function TPyPluginHost.UiAttached: Boolean;
begin
  FDataLock.Enter;
  try
    Result := FAttached > 0;
  finally
    FDataLock.Leave;
  end;
end;

procedure TPyPluginHost.DetachUi;
begin
  FDataLock.Enter;
  try
    if FAttached > 0 then Dec(FAttached);
    if FAttached = 0 then FInbox.Clear;
  finally
    FDataLock.Leave;
  end;
end;

procedure TPyPluginHost.TakeMessages(AInto: TList<TPyMsg>);
begin
  FDataLock.Enter;
  try
    AInto.AddRange(FInbox);
    FInbox.Clear;
  finally
    FDataLock.Leave;
  end;
end;

procedure TPyPluginHost.TakeMidiOut(AInto: TList<TPyMidiOut>);
begin
  FDataLock.Enter;
  try
    AInto.AddRange(FMidiOut);
    FMidiOut.Clear;
  finally
    FDataLock.Leave;
  end;
end;

function TPyPluginHost.WriteFrame(AType: Cardinal; const APayload: TBytes): Boolean;
var
  hdr: array[0..1] of Cardinal;
  wrote: DWORD;
begin
  Result := False;
  if FDead or (FStdinW = 0) then Exit;
  hdr[0] := AType;
  hdr[1] := Length(APayload);
  FWriteLock.Enter;
  try
    if not WriteFile(FStdinW, hdr, SizeOf(hdr), wrote, nil) then Exit;
    if Length(APayload) > 0 then
      if not WriteFile(FStdinW, APayload[0], Length(APayload), wrote, nil) then Exit;
    Result := True;
  finally
    FWriteLock.Leave;
  end;
end;

function TPyPluginHost.WriteJson(AType: Cardinal; AObj: TJSONObject): Boolean;
begin
  try
    Result := WriteFrame(AType, TEncoding.UTF8.GetBytes(AObj.ToJSON));
  finally
    AObj.Free;
  end;
end;

function TPyPluginHost.ParamIndex(const AId: string): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FParams) do
    if SameText(FParams[i].Id, AId) then Exit(i);
  Result := -1;
end;

{ ---- starting and stopping ---- }

function TPyPluginHost.Start(const ASource, AFileName, AScriptDir, AValuesJson, AStateJson: string;
  ASampleRate, AChannels, AMaxFrames: Integer; out AError: string): Boolean;
var
  exe, msg: string;
  sa: TSecurityAttributes;
  inR, inW, outR, outW, errR, errW: THandle;
  pipeSize, i: Integer;
  init: TJSONObject;
  v: TJSONValue;
begin
  Result := False;
  AError := '';
  FStartError := '';
  exe := PyFindInterpreter(msg);
  if exe = '' then
  begin
    AError := msg;
    FStartError := msg;
    Exit;
  end;
  PyEnsureSdk(PyPluginsFolder);
  FSampleRate := ASampleRate;
  FChannels := Max(1, AChannels);
  FMaxFrames := Max(16, AMaxFrames);
  for i := 0 to 3 do
  begin
    SetLength(FSlotData[i], FMaxFrames * FChannels);
    FSlotSeq[i] := -1;
  end;
  SetLength(FSendBuf, 24 + FMaxFrames * FChannels * 4);

  FillChar(sa, SizeOf(sa), 0);
  sa.nLength := SizeOf(sa);
  sa.bInheritHandle := True;
  pipeSize := Max(1024 * 1024, 6 * (24 + FMaxFrames * FChannels * 4));
  if not CreatePipe(inR, inW, @sa, pipeSize) or not CreatePipe(outR, outW, @sa, pipeSize) or
     not CreatePipe(errR, errW, @sa, 0) then
  begin
    AError := 'Could not create pipes: ' + SysErrorMessage(GetLastError);
    Exit;
  end;
  SetHandleInformation(inW, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(outR, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(errR, HANDLE_FLAG_INHERIT, 0);

  if not SpawnPython(exe, '-X utf8 -B "' + IncludeTrailingPathDelimiter(PyPluginsFolder) +
       'udaw_plugin.py" --host', PyPluginsFolder, inR, outW, errW, FProc, FThread, AError) then
  begin
    CloseHandle(inR); CloseHandle(inW); CloseHandle(outR); CloseHandle(outW);
    CloseHandle(errR); CloseHandle(errW);
    FStartError := AError;
    Exit;
  end;
  CloseHandle(inR);
  CloseHandle(outW);
  CloseHandle(errW);
  FStdinW := inW;
  FStdoutR := outR;
  FStderrR := errR;
  FReader := TPyPipeThread.Create(Self, False);
  FErrReader := TPyPipeThread.Create(Self, True);

  init := TJSONObject.Create;
  init.AddPair('sample_rate', TJSONNumber.Create(ASampleRate));
  init.AddPair('channels', TJSONNumber.Create(FChannels));
  init.AddPair('max_frames', TJSONNumber.Create(FMaxFrames));
  init.AddPair('source', ASource);
  init.AddPair('filename', AFileName);
  init.AddPair('script_dir', AScriptDir);
  init.AddPair('presets_dir', PyPresetsFolder);
  if AValuesJson <> '' then
  begin
    v := TJSONObject.ParseJSONValue(AValuesJson);
    if v is TJSONObject then init.AddPair('values', v) else v.Free;
  end;
  if AStateJson <> '' then
  begin
    v := TJSONObject.ParseJSONValue(AStateJson);
    if v <> nil then init.AddPair('state', v);
  end;
  if not WriteJson(MSG_INIT, init) then
  begin
    AError := 'The Python process stopped before it could be configured.';
    FStartError := AError;
    Stop;
    Exit;
  end;
  if FReadyEvt.WaitFor(25000) <> wrSignaled then
  begin
    AError := 'The plug-in did not finish loading within 25 seconds.';
    if FLogRing.Count > 0 then AError := AError + #13#10 + LogText;
    FStartError := AError;
    Stop;
    Exit;
  end;
  if not FReady then
  begin
    AError := FStartError;
    if AError = '' then AError := 'The plug-in failed to load.';
    Stop;
    Exit;
  end;
  Result := True;
end;

procedure TPyPluginHost.KillProcess;
begin
  if FProc <> 0 then
  begin
    if WaitForSingleObject(FProc, 0) = WAIT_TIMEOUT then TerminateProcess(FProc, 1);
  end;
end;

procedure TPyPluginHost.Stop;
begin
  if FStopping then Exit;
  FStopping := True;
  if (FProc <> 0) and not FDead then
  begin
    WriteFrame(MSG_SHUTDOWN, nil);
    WaitForSingleObject(FProc, 400);
  end;
  KillProcess;
  FDead := True;
  if FStdinW <> 0 then begin CloseHandle(FStdinW); FStdinW := 0; end;
  { the dead process closes the write ends of its pipes, which ends the reader threads }
  if FReader <> nil then
  begin
    FReader.WaitFor;
    FreeAndNil(FReader);
  end;
  if FErrReader <> nil then
  begin
    FErrReader.WaitFor;
    FreeAndNil(FErrReader);
  end;
  if FStdoutR <> 0 then begin CloseHandle(FStdoutR); FStdoutR := 0; end;
  if FStderrR <> 0 then begin CloseHandle(FStderrR); FStderrR := 0; end;
  if FThread <> 0 then begin CloseHandle(FThread); FThread := 0; end;
  if FProc <> 0 then begin CloseHandle(FProc); FProc := 0; end;
  FReadyEvt.SetEvent;
  FReplyEvt.SetEvent;
  FStateEvt.SetEvent;
end;

{ ---- reader threads ---- }

procedure TPyPluginHost.ReaderLoop;
var
  hdr: array[0..1] of Cardinal;
  payload: TBytes;
begin
  while not FStopping do
  begin
    if not ReadExact(FStdoutR, hdr, SizeOf(hdr)) then Break;
    if hdr[1] > MAX_FRAME_BYTES then Break;
    SetLength(payload, hdr[1]);
    if (hdr[1] > 0) and not ReadExact(FStdoutR, payload[0], hdr[1]) then Break;
    try
      HandleFrame(hdr[0], payload);
    except
      on E: Exception do AddLog('host: ' + E.Message);
    end;
  end;
  if not FStopping then
  begin
    FDead := True;
    if FLastError = '' then FLastError := 'The Python process ended unexpectedly.';
    if not FReady then
    begin
      if FStartError = '' then
        FStartError := 'The Python process ended while loading the plug-in.' + #13#10 + LogText;
      FReadyEvt.SetEvent;
    end;
    Enqueue(pmError, FLastError);
  end;
  FReplyEvt.SetEvent;
  FStateEvt.SetEvent;
end;

procedure TPyPluginHost.StderrLoop;
var
  buf: array[0..1023] of AnsiChar;
  got: DWORD;
  acc: string;
  raw: AnsiString;
  nl: Integer;
begin
  acc := '';
  while not FStopping do
  begin
    if not ReadFile(FStderrR, buf, SizeOf(buf), got, nil) or (got = 0) then Break;
    SetString(raw, PAnsiChar(@buf[0]), got);
    acc := acc + UTF8ToString(raw);
    repeat
      nl := Pos(#10, acc);
      if nl = 0 then Break;
      AddLog('[stderr] ' + TrimRight(Copy(acc, 1, nl - 1)));
      Enqueue(pmLog, 'error|' + TrimRight(Copy(acc, 1, nl - 1)));
      Delete(acc, 1, nl);
    until False;
  end;
end;

procedure TPyPluginHost.HandleFrame(AType: Cardinal; const APayload: TBytes);
var
  seq: UInt64;
  frames, chans, slot: Cardinal;
  i: Integer;
  m: TPyMidiOut;
  txt: string;
  o: TJSONValue;
begin
  case AType of
    RSP_PROCESSED:
      begin
        if Length(APayload) < 16 then Exit;
        seq := PUInt64(@APayload[0])^;
        frames := PCardinal(@APayload[8])^;
        chans := PCardinal(@APayload[12])^;
        if (Integer(chans) <> FChannels) or (Integer(frames) > FMaxFrames) or
           (Length(APayload) < Integer(16 + frames * chans * 4)) then Exit;
        slot := seq and 3;
        FDataLock.Enter;
        try
          Move(APayload[16], FSlotData[slot][0], frames * chans * 4);
          FSlotFrames[slot] := frames;
          FSlotSeq[slot] := Int64(seq);
          if Int64(seq) > FHighReply then FHighReply := Int64(seq);
        finally
          FDataLock.Leave;
        end;
        FReplyEvt.SetEvent;
      end;
    RSP_READY:
      begin
        HandleReady(TEncoding.UTF8.GetString(APayload));
        FReadyEvt.SetEvent;
      end;
    RSP_LOG:
      begin
        txt := TEncoding.UTF8.GetString(APayload);
        o := TJSONObject.ParseJSONValue(txt);
        try
          if o is TJSONObject then
          begin
            AddLog(TJSONObject(o).GetValue<string>('text', ''));
            Enqueue(pmLog, TJSONObject(o).GetValue<string>('level', 'info') + '|' +
              TJSONObject(o).GetValue<string>('text', ''));
          end;
        finally
          o.Free;
        end;
      end;
    RSP_MIDI:
      begin
        FDataLock.Enter;
        try
          i := 0;
          while i + 2 < Length(APayload) do
          begin
            m.Status := APayload[i];
            m.Data1 := APayload[i + 1];
            m.Data2 := APayload[i + 2];
            if FMidiOut.Count >= MIDI_OUT_CAP then FMidiOut.Delete(0);
            FMidiOut.Add(m);
            Inc(i, 3);
          end;
        finally
          FDataLock.Leave;
        end;
      end;
    RSP_UI:
      HandleUi(TEncoding.UTF8.GetString(APayload));
    RSP_PAINT:
      Enqueue(pmPaint, TEncoding.UTF8.GetString(APayload));
    RSP_STATE:
      begin
        FStateJson := TEncoding.UTF8.GetString(APayload);
        FStateEvt.SetEvent;
      end;
    RSP_ERROR:
      begin
        txt := TEncoding.UTF8.GetString(APayload);
        o := TJSONObject.ParseJSONValue(txt);
        try
          if o is TJSONObject then
          begin
            FLastError := TJSONObject(o).GetValue<string>('text', 'error');
            AddLog(FLastError);
            if TJSONObject(o).GetValue<Boolean>('fatal', False) and not FReady then
            begin
              FStartError := FLastError;
              FReadyEvt.SetEvent;
            end;
            Enqueue(pmError, FLastError);
          end;
        finally
          o.Free;
        end;
      end;
  end;
end;

procedure TPyPluginHost.HandleReady(const AJson: string);
var
  o: TJSONObject;
  v: TJSONValue;
  a, ch: TJSONArray;
  p: TJSONObject;
  i, j: Integer;
  ui: TJSONValue;
begin
  v := TJSONObject.ParseJSONValue(AJson);
  try
    if not (v is TJSONObject) then
    begin
      FStartError := 'The plug-in sent an unreadable description.';
      Exit;
    end;
    o := TJSONObject(v);
    FName := o.GetValue<string>('name', 'Python plug-in');
    FVendor := o.GetValue<string>('vendor', '');
    FAuthor := o.GetValue<string>('author', '');
    FVersion := o.GetValue<string>('version', '');
    FDescription := o.GetValue<string>('description', '');
    FPythonVersion := o.GetValue<string>('python', '');
    FBuffered := o.GetValue<Boolean>('buffered', False);
    ui := o.GetValue('ui');
    if ui <> nil then FUiJson := ui.ToJSON else FUiJson := '';
    a := o.GetValue('params') as TJSONArray;
    if a <> nil then
    begin
      SetLength(FParams, a.Count);
      for i := 0 to a.Count - 1 do
      begin
        p := a.Items[i] as TJSONObject;
        FParams[i].Id := p.GetValue<string>('id', '');
        FParams[i].Name := p.GetValue<string>('name', FParams[i].Id);
        FParams[i].UnitText := p.GetValue<string>('unit', '');
        FParams[i].Group := p.GetValue<string>('group', '');
        FParams[i].Min := p.GetValue<Double>('min', 0);
        FParams[i].Max := p.GetValue<Double>('max', 1);
        FParams[i].DefaultValue := p.GetValue<Double>('default', 0);
        FParams[i].Value := p.GetValue<Double>('value', FParams[i].DefaultValue);
        FParams[i].Step := p.GetValue<Double>('step', 0);
        FParams[i].Log := p.GetValue<Boolean>('log', False);
        FParams[i].Decimals := p.GetValue<Integer>('decimals', 2);
        case IndexText(p.GetValue<string>('kind', 'float'), ['float', 'int', 'bool', 'choice']) of
          1: FParams[i].Kind := ppInt;
          2: FParams[i].Kind := ppBool;
          3: FParams[i].Kind := ppChoice;
        else
          FParams[i].Kind := ppFloat;
        end;
        ch := p.GetValue('choices') as TJSONArray;
        if ch <> nil then
        begin
          SetLength(FParams[i].Choices, ch.Count);
          for j := 0 to ch.Count - 1 do FParams[i].Choices[j] := ch.Items[j].Value;
        end;
      end;
    end;
    FReady := True;
  finally
    v.Free;
  end;
end;

{ the plug-in moved parameters itself: keep our copy in step, then let the window know }
procedure TPyPluginHost.HandleUi(const AJson: string);
var
  v: TJSONValue;
  prm: TJSONObject;
  pair: TJSONPair;
  idx: Integer;
begin
  v := TJSONObject.ParseJSONValue(AJson);
  try
    if v is TJSONObject then
    begin
      prm := TJSONObject(v).GetValue('params') as TJSONObject;
      if prm <> nil then
      begin
        FDataLock.Enter;
        try
          for pair in prm do
          begin
            idx := ParamIndex(pair.JsonString.Value);
            if (idx >= 0) and (pair.JsonValue is TJSONNumber) then FParams[idx].Value := FParams[idx].Clamp(TJSONNumber(pair.JsonValue).AsDouble);
          end;
        finally
          FDataLock.Leave;
        end;
      end;
    end;
  finally
    v.Free;
  end;
  Enqueue(pmUi, AJson);
end;

{ ---- audio ---- }

function TPyPluginHost.ProcessBlock(const AIn, AOut: array of System.PSingle; AFrames: Integer): Boolean;
var
  nch, c, slot, timeoutMs: Integer;
  want, mySeq: UInt64;
  bytesPer: Integer;
  deadline: UInt64;
  got: Boolean;
  wrote: DWORD;
  hdr: PCardinal;
begin
  Result := False;
  if (not FReady) or FDead or (AFrames <= 0) or (AFrames > FMaxFrames) then Exit;
  nch := Min(Length(AIn), Min(Length(AOut), FChannels));
  if nch <> FChannels then Exit;
  Inc(FBlocks);
  mySeq := FSeq;
  { too many blocks outstanding: the script cannot keep up - skip this one rather than queue }
  if Int64(mySeq) - FHighReply > 3 then
  begin
    Inc(FDropped);
    Exit;
  end;
  Inc(FSeq);
  bytesPer := AFrames * 4;
  hdr := PCardinal(@FSendBuf[0]);
  hdr^ := MSG_PROCESS;
  PCardinal(@FSendBuf[4])^ := 16 + nch * bytesPer;
  PUInt64(@FSendBuf[8])^ := mySeq;
  PCardinal(@FSendBuf[16])^ := AFrames;
  PCardinal(@FSendBuf[20])^ := nch;
  for c := 0 to nch - 1 do Move(AIn[c]^, FSendBuf[24 + c * bytesPer], bytesPer);
  FReplyEvt.ResetEvent;
  FWriteLock.Enter;
  try
    if not WriteFile(FStdinW, FSendBuf[0], 24 + nch * bytesPer, wrote, nil) then
    begin
      FDead := True;
      Exit;
    end;
  finally
    FWriteLock.Leave;
  end;

  if FBuffered then
  begin
    if mySeq = 0 then Exit;            // nothing back yet: dry for the very first block
    want := mySeq - 1;
  end
  else
    want := mySeq;

  if GOfflineDepth > 0 then
    timeoutMs := 60000
  else
    timeoutMs := Max(2, Round(AFrames / Max(1, FSampleRate) * 1000.0 * 0.85));
  deadline := GetTickCount64 + UInt64(timeoutMs);
  got := False;
  slot := Integer(want and 3);
  repeat
    FDataLock.Enter;
    try
      if (FSlotSeq[slot] = Int64(want)) and (FSlotFrames[slot] = AFrames) then
      begin
        for c := 0 to nch - 1 do
          Move(FSlotData[slot][c * AFrames], AOut[c]^, bytesPer);
        FSlotSeq[slot] := -1;
        got := True;
      end;
    finally
      FDataLock.Leave;
    end;
    if got or FDead then Break;
    if GetTickCount64 >= deadline then Break;
    FReplyEvt.WaitFor(Max(1, Integer(deadline - GetTickCount64)));
    FReplyEvt.ResetEvent;
  until False;
  if not got then Inc(FLate);
  Result := got;
end;

procedure TPyPluginHost.ResetDsp;
begin
  WriteFrame(MSG_RESET, nil);
end;

{ ---- parameters ---- }

function TPyPluginHost.ParamCount: Integer;
begin
  Result := Length(FParams);
end;

function TPyPluginHost.GetParam(AIndex: Integer): TPyParam;
begin
  FDataLock.Enter;
  try
    Result := FParams[AIndex];
  finally
    FDataLock.Leave;
  end;
end;

function TPyPluginHost.ParamValue(const AId: string; ADefault: Double): Double;
var
  i: Integer;
begin
  Result := ADefault;
  FDataLock.Enter;
  try
    i := ParamIndex(AId);
    if i >= 0 then Result := FParams[i].Value;
  finally
    FDataLock.Leave;
  end;
end;

procedure TPyPluginHost.SetParam(const AId: string; AValue: Double);
var
  i: Integer;
  o: TJSONObject;
  v: Double;
begin
  FDataLock.Enter;
  try
    i := ParamIndex(AId);
    if i < 0 then Exit;
    v := FParams[i].Clamp(AValue);
    if v = FParams[i].Value then Exit;
    FParams[i].Value := v;
  finally
    FDataLock.Leave;
  end;
  o := TJSONObject.Create;
  o.AddPair('id', AId);
  o.AddPair('value', TJSONNumber.Create(v));
  WriteJson(MSG_PARAM, o);
end;

procedure TPyPluginHost.SetParamNorm(AIndex: Integer; ANorm: Double);
var
  prm: TPyParam;
begin
  if (AIndex < 0) or (AIndex >= Length(FParams)) then Exit;
  prm := GetParam(AIndex);
  SetParam(prm.Id, prm.FromNorm(ANorm));
end;

function TPyPluginHost.ParamNames: string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(FParams) do
  begin
    if i > 0 then Result := Result + #10;
    Result := Result + FParams[i].Name;
  end;
end;

{ ---- window plumbing ---- }

procedure TPyPluginHost.SendEvent(const AControl, AEvent, AValue: string; X, Y, AButton: Integer);
var
  o: TJSONObject;
  num: Double;
begin
  o := TJSONObject.Create;
  o.AddPair('id', AControl);
  o.AddPair('event', AEvent);
  if (AValue <> '') and TryStrToFloat(AValue, num, TFormatSettings.Invariant) then
    o.AddPair('value', TJSONNumber.Create(num))
  else if AValue <> '' then
    o.AddPair('value', AValue);
  o.AddPair('x', TJSONNumber.Create(X));
  o.AddPair('y', TJSONNumber.Create(Y));
  o.AddPair('button', TJSONNumber.Create(AButton));
  WriteJson(MSG_EVENT, o);
end;

procedure TPyPluginHost.RequestPaint(const AControl: string; AWidth, AHeight: Integer);
var
  o: TJSONObject;
begin
  o := TJSONObject.Create;
  o.AddPair('id', AControl);
  o.AddPair('w', TJSONNumber.Create(AWidth));
  o.AddPair('h', TJSONNumber.Create(AHeight));
  WriteJson(MSG_PAINT, o);
end;

procedure TPyPluginHost.Tick;
begin
  WriteFrame(MSG_TICK, nil);
end;

procedure TPyPluginHost.SendMidi(AStatus, AData1, AData2: Byte);
var
  b: TBytes;
begin
  SetLength(b, 3);
  b[0] := AStatus;
  b[1] := AData1;
  b[2] := AData2;
  WriteFrame(MSG_MIDI, b);
end;

function TPyPluginHost.CaptureState(ATimeoutMs: Integer): string;
begin
  Result := '';
  if (not FReady) or FDead then Exit;
  FStateJson := '';
  FStateEvt.ResetEvent;
  if not WriteFrame(MSG_GETSTATE, nil) then Exit;
  if FStateEvt.WaitFor(ATimeoutMs) = wrSignaled then Result := FStateJson;
end;

procedure TPyPluginHost.RestoreState(const AStateJson: string);
begin
  if (AStateJson <> '') and not FDead then WriteFrame(MSG_SETSTATE, TEncoding.UTF8.GetBytes(AStateJson));
end;

{ ---------------- registry ---------------- }

constructor TPyLiveRegistry.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FMap := TDictionary<string, TPyPluginHost>.Create;
end;

destructor TPyLiveRegistry.Destroy;
begin
  FMap.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TPyLiveRegistry.Register(const AId: string; AHost: TPyPluginHost);
begin
  if AId = '' then Exit;
  FLock.Enter;
  try
    FMap.AddOrSetValue(AId, AHost);
  finally
    FLock.Leave;
  end;
end;

procedure TPyLiveRegistry.Unregister(const AId: string; AHost: TPyPluginHost);
var
  cur: TPyPluginHost;
begin
  FLock.Enter;
  try
    if FMap.TryGetValue(AId, cur) and (cur = AHost) then FMap.Remove(AId);
  finally
    FLock.Leave;
  end;
end;

function TPyLiveRegistry.Acquire(const AId: string): TPyPluginHost;
begin
  Result := nil;
  FLock.Enter;
  try
    if FMap.TryGetValue(AId, Result) then Result.Retain;
  finally
    FLock.Leave;
  end;
end;

procedure TPyLiveRegistry.DrainMidiOut(AInto: TList<TPyMidiOut>);
var
  h: TPyPluginHost;
begin
  FLock.Enter;
  try
    for h in FMap.Values do
      if not h.Dead and not h.UiAttached then h.TakeMidiOut(AInto);
  finally
    FLock.Leave;
  end;
end;

procedure TPyLiveRegistry.BroadcastMidi(AStatus, AData1, AData2: Byte);
var
  h: TPyPluginHost;
begin
  FLock.Enter;
  try
    for h in FMap.Values do
      if not h.Dead and not h.UiAttached then h.SendMidi(AStatus, AData1, AData2);
  finally
    FLock.Leave;
  end;
end;

initialization

finalization
  GLive.Free;
  if GJob <> 0 then CloseHandle(GJob);

end.
