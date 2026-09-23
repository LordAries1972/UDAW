unit UDAW.App;
{$I udaw.inc}

{ Application bootstrap for Phase 1.

  TUDAWApp wires the core platform framework together in a defined order and
  tears it down cleanly:

    1. detect platform
    2. resolve + create the standard directories
    3. start the logger with console + rolling-file sinks
    4. load configuration (creating it with defaults on first run)
    5. apply the configured log level
    6. probe secure storage and record which provider is active
    7. create the background job manager

  It owns no UI. Both the VCL (Delphi) and LCL (Lazarus) executables create a
  TUDAWApp, then show the main form, then free the app on shutdown. }

interface

uses
  SysUtils, Classes,
  UDAW.Types, UDAW.Platform, UDAW.Paths, UDAW.Config, UDAW.Logging,
  UDAW.Jobs, UDAW.SecureStorage, UDAW.Audio.Engine;

type
  TUDAWApp = class
  private
    FPlatform: TPlatformInfo;
    FPaths: TUDAWPaths;
    FConfig: TConfig;
    FJobs: TJobManager;
    FAudio: TAudioEngine;
    FSecure: ISecureStore;
    FMemLog: TMemoryLogSink;
    FConsoleSink: ILogSink;
    FFileSink: ILogSink;
    FStartedUTC: TDateTime;
    procedure StartLogging;
    procedure LoadConfiguration;
  public
    constructor Create;
    destructor Destroy; override;

    { Idempotent-safe: call once at startup. Raises EUDAWError on a fatal
      problem (e.g. the config directory cannot be created). }
    procedure Initialize;
    procedure Shutdown;

    function ParseLogLevel(const S: string; ADefault: TLogLevel): TLogLevel;
    function DescribeStartup: string;

    property Platform: TPlatformInfo read FPlatform;
    property Paths: TUDAWPaths read FPaths;
    property Config: TConfig read FConfig;
    property Jobs: TJobManager read FJobs;
    property Audio: TAudioEngine read FAudio;
    property Secure: ISecureStore read FSecure;
    { In-memory tail of the log, for the UI's live view. }
    property MemoryLog: TMemoryLogSink read FMemLog;
  end;

{ Process-wide accessor. The executable creates this once. }
function App: TUDAWApp;
procedure SetApp(AApp: TUDAWApp);

implementation

uses
  UDAW.Errors;

const
  SUBSYS = 'App';

var
  GApp: TUDAWApp;

function App: TUDAWApp;
begin
  Result := GApp;
end;

procedure SetApp(AApp: TUDAWApp);
begin
  GApp := AApp;
end;

{ TUDAWApp }

constructor TUDAWApp.Create;
begin
  inherited Create;
  FStartedUTC := Now;
end;

destructor TUDAWApp.Destroy;
begin
  Shutdown;
  inherited Destroy;
end;

function TUDAWApp.ParseLogLevel(const S: string; ADefault: TLogLevel): TLogLevel;
var
  t: string;
begin
  t := LowerCase(Trim(S));
  if t = 'trace' then Result := llTrace
  else if t = 'debug' then Result := llDebug
  else if t = 'info' then Result := llInfo
  else if (t = 'warn') or (t = 'warning') then Result := llWarn
  else if t = 'error' then Result := llError
  else if (t = 'crit') or (t = 'critical') then Result := llCritical
  else Result := ADefault;
end;

procedure TUDAWApp.StartLogging;
var
  maxBytes: Int64;
  lvlStr: string;
begin
  { Config is already loaded, so the sinks can be created with the
    configured level and rotation size straight away - no later swap. }
  lvlStr := FConfig.GetString(CFG_SEC_LOGGING, CFG_LOG_LEVEL, 'info');
  maxBytes := FConfig.GetInt64(CFG_SEC_LOGGING, CFG_LOG_MAXBYTES, 8 * 1024 * 1024);
  if maxBytes < 64 * 1024 then
    maxBytes := 64 * 1024;

  FConsoleSink := TConsoleLogSink.Create(llWarn);
  FFileSink := TFileLogSink.Create(FPaths.Logs, maxBytes);
  FMemLog := TMemoryLogSink.Create(4000);

  Logger.AddSink(FConsoleSink);
  Logger.AddSink(FFileSink);
  Logger.AddSink(FMemLog);
  Logger.SetMinLevel(ParseLogLevel(lvlStr, llInfo));
end;

procedure TUDAWApp.LoadConfiguration;
begin
  FConfig := TConfig.Create(FPaths.Config + 'udaw.ini');
end;

procedure TUDAWApp.Initialize;
begin
  FPlatform := CurrentPlatform;

  UDAW.Paths.EnsureDirs;
  FPaths := UDAW.Paths.Paths;

  LoadConfiguration;
  StartLogging;

  Logger.Info(SUBSYS, '=== ' + UDAWFullVersionString + ' starting ===');
  Logger.Info(SUBSYS, 'Platform: ' + FPlatform.Summary);
  Logger.Info(SUBSYS, 'Paths:' + sLineBreak + FPaths.Summary);
  Logger.Info(SUBSYS, 'Config: ' + FConfig.Path);

  if not FConfig.GetBool(CFG_SEC_GENERAL, CFG_GEN_FIRSTRUN, False) then
  begin
    Logger.Info(SUBSYS, 'First run detected - configuration created with defaults');
    FConfig.SetBool(CFG_SEC_GENERAL, CFG_GEN_FIRSTRUN, True);
    FConfig.Save;
  end;

  try
    FSecure := SecureStore;
    if FSecure.IsAvailable then
      Logger.Info(SUBSYS, 'Secure storage: ' + FSecure.ProviderName + ' (available)')
    else
      Logger.Warn(SUBSYS, 'Secure storage: ' + FSecure.ProviderName +
        ' (NOT available - AI credential storage will be disabled)');
  except
    on E: Exception do
    begin
      FSecure := nil;
      Logger.LogException(SUBSYS, E, 'secure storage probe failed');
    end;
  end;

  FJobs := TJobManager.Create(0);
  Logger.Info(SUBSYS, Format('Job manager: %d worker threads', [FJobs.WorkerCount]));

  { Audio device engine (Phase 2). A missing / busy device is never fatal:
    Open logs the problem, leaves the engine in aesFailed, and the DAW keeps
    running silently until the user picks a working device. }
  FAudio := TAudioEngine.Create(FConfig);
  try
    if FConfig.GetBool(CFG_SEC_AUDIO, CFG_AUDIO_AUTOSTART, True) then
    begin
      if FAudio.Open(True) then
        Logger.Info(SUBSYS, 'Audio: ' + FAudio.Granted.Describe)
      else
        Logger.Warn(SUBSYS, 'Audio: no output device started (engine ' +
          AudioEngineStateName(FAudio.State) + ')');
    end
    else
      Logger.Info(SUBSYS, 'Audio: autostart disabled');
  except
    on E: Exception do
      Logger.LogException(SUBSYS, E, 'audio engine init');
  end;

  Logger.Info(SUBSYS, 'Startup complete.');
  Logger.Flush(1000);
end;

procedure TUDAWApp.Shutdown;
begin
  if (FJobs = nil) and (FConfig = nil) then
    Exit;

  if Logger <> nil then
    Logger.Info(SUBSYS, '=== ' + UDAW_SHORT_NAME + ' shutting down ===');

  if FAudio <> nil then
  begin
    try
      FAudio.Close;
    except
      on E: Exception do
        if Logger <> nil then Logger.LogException(SUBSYS, E, 'audio engine shutdown');
    end;
    FreeAndNil(FAudio);
  end;

  if FJobs <> nil then
  begin
    FJobs.CancelAll;
    FJobs.WaitAll(3000);
    FreeAndNil(FJobs);
  end;

  if FConfig <> nil then
  begin
    try
      if FConfig.Dirty then
        FConfig.Save;
    except
      on E: Exception do
        if Logger <> nil then Logger.LogException(SUBSYS, E, 'config save on shutdown');
    end;
    FreeAndNil(FConfig);
  end;

  FSecure := nil;

  if Logger <> nil then
  begin
    Logger.Flush(1500);
    { drop our sinks before the logger singleton is torn down in finalization }
    if FMemLog <> nil then Logger.RemoveSink(FMemLog);
    if FFileSink <> nil then Logger.RemoveSink(FFileSink);
    if FConsoleSink <> nil then Logger.RemoveSink(FConsoleSink);
  end;
  FFileSink := nil;
  FConsoleSink := nil;
  FMemLog := nil;
end;

function TUDAWApp.DescribeStartup: string;
var
  sb: TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    sb.AppendLine(UDAWFullVersionString);
    sb.AppendLine('');
    sb.AppendLine('Platform');
    sb.AppendLine('  ' + FPlatform.Summary);
    sb.AppendLine('  kernel target : ' + FPlatform.KernelName);
    sb.AppendLine('  64-bit OS     : ' + BoolToStr(FPlatform.Is64BitOS, True));
    sb.AppendLine('');
    sb.AppendLine('Directories');
    sb.AppendLine('  ' + StringReplace(FPaths.Summary, sLineBreak,
      sLineBreak + '  ', [rfReplaceAll]));
    sb.AppendLine('');
    sb.AppendLine('Configuration');
    if FConfig <> nil then
      sb.AppendLine('  file : ' + FConfig.Path);
    sb.AppendLine('  log level : ' + LevelName(Logger.MinLevel));
    sb.AppendLine('');
    sb.AppendLine('Secure storage');
    if FSecure <> nil then
      sb.AppendLine(Format('  %s : %s', [FSecure.ProviderName,
        BoolToStr(FSecure.IsAvailable, True)]))
    else
      sb.AppendLine('  (unavailable)');
    sb.AppendLine('');
    sb.AppendLine('Jobs');
    if FJobs <> nil then
      sb.AppendLine(Format('  worker threads : %d', [FJobs.WorkerCount]));
    sb.AppendLine('');
    sb.AppendLine('Audio');
    if FAudio <> nil then
    begin
      sb.AppendLine('  backend : ' + FAudio.BackendName);
      sb.AppendLine('  state   : ' + AudioEngineStateName(FAudio.State));
      sb.AppendLine('  stream  : ' + FAudio.Granted.Describe);
    end
    else
      sb.AppendLine('  (engine not created)');
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

end.
