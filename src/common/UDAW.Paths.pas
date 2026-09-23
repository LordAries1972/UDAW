unit UDAW.Paths;
{$I udaw.inc}

{ Canonical filesystem locations for UDAW, following platform conventions:

    Override: if the UDAW_HOME environment variable is set, every root
              (config, data, cache, logs, temp) is placed under
              <UDAW_HOME>\UDAW\<Config|Data|Cache|Logs|Temp>\ instead of the
              platform locations below. Use it to keep all runtime files off
              the system drive.

    Windows : %APPDATA%\Ultimanium\UDAW          (config, data)
              %LOCALAPPDATA%\Ultimanium\UDAW\... (cache, logs)
    macOS   : ~/Library/Application Support/UDAW  (config, data)
              ~/Library/Caches/UDAW               (cache)
              ~/Library/Logs/UDAW                 (logs)
    Linux   : $XDG_CONFIG_HOME|~/.config/UDAW     (config)
              $XDG_DATA_HOME|~/.local/share/UDAW  (data)
              $XDG_CACHE_HOME|~/.cache/UDAW       (cache)
              $XDG_STATE_HOME|~/.local/state/UDAW/logs (logs)

  All accessors return a path WITH a trailing delimiter. EnsureDirs must be
  called once at startup; it creates every directory and raises EUDAWError on
  failure. }

interface

uses
  SysUtils, Classes;

type
  TUDAWPaths = record
    Home: string;
    Config: string;
    Data: string;
    Cache: string;
    Logs: string;
    Temp: string;         // per-run scratch, created under system temp
    ExecutableFile: string;
    ExecutableDir: string;
    function Summary: string;
  end;

function Paths: TUDAWPaths;
procedure EnsureDirs;

{ User-chosen locations for the two big, disposable folders (Temp = render /
  download scratch, Cache = decoded/generated media), so a user with a small
  system drive can keep them elsewhere. Stored in a bootstrap file in the
  fixed Config folder (Config itself can't move - it is where settings are
  found). Empty = the platform default. Read once at startup, so a change
  applies from the next launch. }
function LoadFolderOverrides(out ATemp, ACache: string): Boolean;
procedure SaveFolderOverrides(const ATemp, ACache: string);

{ Convenience: join a relative path onto one of the roots. }
function ConfigFile(const ARelative: string): string;
function DataFile(const ARelative: string): string;
function CacheFile(const ARelative: string): string;
function LogFile(const ARelative: string): string;

implementation

uses
  {$IFNDEF FPC}
  IOUtils,
  {$ENDIF}
  UDAW.Types, UDAW.Errors;

var
  GPaths: TUDAWPaths;
  GResolved: Boolean = False;

function SysTempDir: string;
begin
  {$IFDEF FPC}
  Result := GetTempDir;
  {$ELSE}
  Result := TPath.GetTempPath;
  {$ENDIF}
  if Result = '' then
    Result := GetCurrentDir;
end;

function HomeDir: string;
begin
  {$IFDEF UDAW_WINDOWS}
  Result := GetEnvironmentVariable('USERPROFILE');
  if Result = '' then
    Result := GetEnvironmentVariable('HOMEDRIVE') + GetEnvironmentVariable('HOMEPATH');
  {$ELSE}
  Result := GetEnvironmentVariable('HOME');
  {$ENDIF}
  if Result = '' then
    Result := GetCurrentDir;
  Result := IncludeTrailingPathDelimiter(Result);
end;

function XDG(const AVar, ADefaultSub: string; const AHome: string): string;
begin
  Result := GetEnvironmentVariable(AVar);
  if Result = '' then
    Result := AHome + ADefaultSub
  else
    Result := IncludeTrailingPathDelimiter(Result) + UDAW_SHORT_NAME;
  Result := IncludeTrailingPathDelimiter(Result);
end;

function FolderOverrideFile: string;
begin
  Result := GPaths.Config + 'folders.ini';
end;

function LoadFolderOverrides(out ATemp, ACache: string): Boolean;
var
  sl: TStringList;
begin
  ATemp := '';
  ACache := '';
  Paths;
  Result := FileExists(FolderOverrideFile);
  if not Result then Exit;
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile(FolderOverrideFile);
      ATemp := Trim(sl.Values['temp']);
      ACache := Trim(sl.Values['cache']);
    except
      Result := False;
    end;
  finally
    sl.Free;
  end;
end;

procedure SaveFolderOverrides(const ATemp, ACache: string);
var
  sl: TStringList;
begin
  Paths;
  ForceDirectories(GPaths.Config);
  sl := TStringList.Create;
  try
    sl.Add('temp=' + Trim(ATemp));
    sl.Add('cache=' + Trim(ACache));
    sl.SaveToFile(FolderOverrideFile);
  finally
    sl.Free;
  end;
end;

procedure ApplyFolderOverrides;
var
  t, c: string;
begin
  if not LoadFolderOverrides(t, c) then Exit;
  if t <> '' then GPaths.Temp := IncludeTrailingPathDelimiter(t);
  if c <> '' then GPaths.Cache := IncludeTrailingPathDelimiter(c);
end;

procedure Resolve;
var
  home, appData, localAppData, baseOverride: string;
begin
  FillChar(GPaths, SizeOf(GPaths), 0);
  home := HomeDir;
  GPaths.Home := home;
  GPaths.ExecutableFile := ParamStr(0);
  GPaths.ExecutableDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));

  baseOverride := Trim(GetEnvironmentVariable('UDAW_HOME'));
  if baseOverride <> '' then
  begin
    { Single relocatable root - keeps every runtime file off the system drive. }
    baseOverride := IncludeTrailingPathDelimiter(baseOverride) + UDAW_SHORT_NAME + PathDelim;
    GPaths.Config := baseOverride + 'Config' + PathDelim;
    GPaths.Data   := baseOverride + 'Data' + PathDelim;
    GPaths.Cache  := baseOverride + 'Cache' + PathDelim;
    GPaths.Logs   := baseOverride + 'Logs' + PathDelim;
    GPaths.Temp   := baseOverride + 'Temp' + PathDelim;
    GResolved := True;
    Exit;
  end;

  {$IF DEFINED(UDAW_WINDOWS)}
  appData := GetEnvironmentVariable('APPDATA');
  if appData = '' then appData := home + 'AppData\Roaming';
  localAppData := GetEnvironmentVariable('LOCALAPPDATA');
  if localAppData = '' then localAppData := home + 'AppData\Local';
  appData := IncludeTrailingPathDelimiter(appData) + UDAW_VENDOR_NAME + PathDelim + UDAW_SHORT_NAME + PathDelim;
  localAppData := IncludeTrailingPathDelimiter(localAppData) + UDAW_VENDOR_NAME + PathDelim + UDAW_SHORT_NAME + PathDelim;
  GPaths.Config := appData;
  GPaths.Data := appData;
  GPaths.Cache := localAppData + 'Cache' + PathDelim;
  GPaths.Logs := localAppData + 'Logs' + PathDelim;

  {$ELSEIF DEFINED(UDAW_MACOS)}
  GPaths.Config := home + 'Library/Application Support/' + UDAW_SHORT_NAME + '/';
  GPaths.Data := GPaths.Config;
  GPaths.Cache := home + 'Library/Caches/' + UDAW_SHORT_NAME + '/';
  GPaths.Logs := home + 'Library/Logs/' + UDAW_SHORT_NAME + '/';

  {$ELSE}
  GPaths.Config := XDG('XDG_CONFIG_HOME', '.config' + PathDelim + UDAW_SHORT_NAME, home);
  GPaths.Data := XDG('XDG_DATA_HOME', '.local' + PathDelim + 'share' + PathDelim + UDAW_SHORT_NAME, home);
  GPaths.Cache := XDG('XDG_CACHE_HOME', '.cache' + PathDelim + UDAW_SHORT_NAME, home);
  GPaths.Logs := XDG('XDG_STATE_HOME', '.local' + PathDelim + 'state' + PathDelim + UDAW_SHORT_NAME, home) + 'logs' + PathDelim;
  {$IFEND}

  GPaths.Temp := IncludeTrailingPathDelimiter(SysTempDir) + UDAW_SHORT_NAME + PathDelim;
  GResolved := True;
end;

function Paths: TUDAWPaths;
begin
  if not GResolved then
  begin
    Resolve;
    ApplyFolderOverrides;
  end;
  Result := GPaths;
end;

procedure MakeDir(const APath: string);
begin
  if APath = '' then Exit;
  if DirectoryExists(APath) then Exit;
  if not ForceDirectories(APath) then
    RaiseUDAWFmt(errIO, 'Paths', 'Unable to create directory "%s"', [APath]);
end;

procedure EnsureDirs;
var
  p: TUDAWPaths;
begin
  p := Paths;
  MakeDir(p.Config);
  MakeDir(p.Data);
  MakeDir(p.Cache);
  MakeDir(p.Logs);
  MakeDir(p.Temp);
end;

function ConfigFile(const ARelative: string): string;
begin
  Result := Paths.Config + ARelative;
end;

function DataFile(const ARelative: string): string;
begin
  Result := Paths.Data + ARelative;
end;

function CacheFile(const ARelative: string): string;
begin
  Result := Paths.Cache + ARelative;
end;

function LogFile(const ARelative: string): string;
begin
  Result := Paths.Logs + ARelative;
end;

{ TUDAWPaths }

function TUDAWPaths.Summary: string;
begin
  Result :=
    'config = ' + Config + sLineBreak +
    'data   = ' + Data + sLineBreak +
    'cache  = ' + Cache + sLineBreak +
    'logs   = ' + Logs + sLineBreak +
    'temp   = ' + Temp + sLineBreak +
    'exe    = ' + ExecutableFile;
end;

end.
