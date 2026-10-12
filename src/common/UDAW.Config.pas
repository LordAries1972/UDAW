unit UDAW.Config;
{$I udaw.inc}

{ Application configuration, backed by a human-readable INI file
  (config dir / udaw.ini). Typed accessors with defaults; unknown keys are
  preserved on save. Saving is atomic: written to a temp file and renamed, so
  a crash mid-save can never corrupt the live config (plan rule: "unfinished
  persistence" is forbidden).

  Values here are plain settings only - no secrets. API keys live in
  UDAW.SecureStorage. }

interface

uses
  SysUtils, Classes, IniFiles,
  UDAW.Threading;

type
  TConfig = class
  private
    FPath: string;
    FIni: TMemIniFile;
    FLock: TUDAWLock;
    FDirty: Boolean;
    procedure SeedDefaults;
  public
    constructor Create(const APath: string);
    destructor Destroy; override;

    procedure Reload;
    function Save: Boolean;
    property Path: string read FPath;
    property Dirty: Boolean read FDirty;

    function GetString(const ASection, AKey, ADefault: string): string;
    function GetInt(const ASection, AKey: string; ADefault: Integer): Integer;
    function GetInt64(const ASection, AKey: string; ADefault: Int64): Int64;
    function GetBool(const ASection, AKey: string; ADefault: Boolean): Boolean;
    function GetFloat(const ASection, AKey: string; ADefault: Double): Double;

    procedure SetString(const ASection, AKey, AValue: string);
    procedure SetInt(const ASection, AKey: string; AValue: Integer);
    procedure SetInt64(const ASection, AKey: string; AValue: Int64);
    procedure SetBool(const ASection, AKey: string; AValue: Boolean);
    procedure SetFloat(const ASection, AKey: string; AValue: Double);

    procedure DeleteKey(const ASection, AKey: string);
    procedure Sections(ADest: TStrings);
  end;

{ Well-known keys used by the Phase 1 bootstrap. Later phases add their own
  sections; nothing here forces those subsystems to exist yet. }
const
  CFG_SEC_GENERAL   = 'general';
  CFG_SEC_LOGGING   = 'logging';
  CFG_SEC_PATHS     = 'paths';

  CFG_LOG_LEVEL     = 'level';           // trace|debug|info|warn|error|critical
  CFG_LOG_MAXBYTES  = 'max_file_bytes';
  CFG_GEN_FIRSTRUN  = 'first_run_completed';
  CFG_GEN_LOCALE    = 'locale';
  CFG_GEN_SHOW_HINTS     = 'show_hints';          // system-wide (not per project): rollover hint bubbles, default on
  CFG_GEN_TEMPO_AUTO     = 'tempo_auto_detect';   // 1st imported audio track sets the Timeline BPM (default on)
  CFG_GEN_TL_REFRESH_HZ  = 'timeline_refresh_hz'; // Timeline redraws per second while playing: 5..40 in steps of 5 (default 20)
  CFG_GEN_TEMPO_RESAMPLE = 'tempo_resample';      // conform clip tempo by resampling (pitch follows) instead of phase vocoder (default off)

  { [paths] - user-configurable working directories (Settings tab).  Each is a
    plain absolute folder path, '' meaning "not set / use the built-in
    default".  These are distinct from UDAW.Paths' per-OS Config/Data/Cache/
    Logs/Temp roots, which are fixed platform locations, not user content
    folders. }
  CFG_PATH_PROJECTS    = 'projects_dir';       // default Open/Save project folder
  CFG_PATH_AUDIO_LIB   = 'audio_library_dir';  // where to browse for WAV/MP3/etc.
  CFG_PATH_SFX         = 'sfx_dir';            // sound-effect library folder
  CFG_PATH_EXPORT      = 'export_dir';         // rendered / exported audio
  CFG_PATH_RECORDINGS  = 'recordings_dir';     // captured takes, if not the default

  { AI Composition, Phase 2 (docs/AIPlan.md section 3: "Allow the user to
    define one or more preset locations") - additional catalogue-scan roots
    alongside CFG_PATH_AUDIO_LIB/CFG_PATH_SFX above. See
    UDAW.Browser.Catalogue.TInstrumentCatalogue.ScanRoots. }
  CFG_PATH_INSTRUMENTS = 'instruments_dir';    // virtual-instrument / SoundFont folder
  CFG_PATH_PRESETS     = 'presets_dir';        // preset folder
  CFG_PATH_LOOPS       = 'loops_dir';          // loop library folder
  CFG_PATH_PLUGINS     = 'plugins_dir';        // VST/VST3 plug-in folder
  CFG_PATH_SOUNDFONTS  = 'soundfonts_dir';     // SoundFont (.sf2/.sfz) folder
  CFG_PATH_VOCALS      = 'vocals_dir';         // vocal recording folder

implementation

uses
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}   // expands the inline RenameFile (H2443)
  UDAW.Errors;

function InvariantFS: TFormatSettings;
begin
  Result := FormatSettings;
  Result.DecimalSeparator := '.';
  Result.ThousandSeparator := #0;
end;

constructor TConfig.Create(const APath: string);
begin
  inherited Create;
  FPath := APath;
  FLock := TUDAWLock.Create('config');
  ForceDirectories(ExtractFilePath(FPath));
  FIni := TMemIniFile.Create(FPath{$IFNDEF FPC}, TEncoding.UTF8{$ENDIF});
  SeedDefaults;
end;

destructor TConfig.Destroy;
begin
  if FDirty then
  try
    Save;
  except
    { destructor must not raise }
  end;
  FIni.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TConfig.SeedDefaults;
var
  changed: Boolean;

  procedure Ensure(const Sec, Key, Val: string);
  begin
    if not FIni.ValueExists(Sec, Key) then
    begin
      FIni.WriteString(Sec, Key, Val);
      changed := True;
    end;
  end;

begin
  changed := False;
  Ensure(CFG_SEC_GENERAL, CFG_GEN_FIRSTRUN, '0');
  Ensure(CFG_SEC_GENERAL, CFG_GEN_LOCALE, '');
  Ensure(CFG_SEC_LOGGING, CFG_LOG_LEVEL, 'info');
  Ensure(CFG_SEC_LOGGING, CFG_LOG_MAXBYTES, IntToStr(8 * 1024 * 1024));
  if changed then
  begin
    FDirty := True;
    Save;
  end;
end;

procedure TConfig.Reload;
begin
  FLock.Enter;
  try
    FIni.Free;
    FIni := TMemIniFile.Create(FPath{$IFNDEF FPC}, TEncoding.UTF8{$ENDIF});
    FDirty := False;
  finally
    FLock.Leave;
  end;
end;

function TConfig.Save: Boolean;
var
  tmp, bak: string;
  lines: TStringList;
begin
  FLock.Enter;
  try
    tmp := FPath + '.tmp';
    bak := FPath + '.bak';

    lines := TStringList.Create;
    try
      FIni.GetStrings(lines);
      if FileExists(tmp) then
        SysUtils.DeleteFile(tmp);
      lines.SaveToFile(tmp);
    finally
      lines.Free;
    end;

    if not FileExists(tmp) then
      RaiseUDAWFmt(errConfig, 'Config', 'Save produced no file at "%s"', [tmp]);

    { Atomic-as-possible swap: keep the previous file as .bak, then move the
      new file into place. RenameFile within one directory is atomic on POSIX;
      on Windows the .bak step clears the way for the final move. }
    if FileExists(FPath) then
    begin
      if FileExists(bak) then
        SysUtils.DeleteFile(bak);
      RenameFile(FPath, bak);
    end;
    if not RenameFile(tmp, FPath) then
      RaiseUDAWFmt(errConfig, 'Config', 'Could not move "%s" to "%s"', [tmp, FPath]);

    FDirty := False;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TConfig.GetString(const ASection, AKey, ADefault: string): string;
begin
  FLock.Enter;
  try
    Result := FIni.ReadString(ASection, AKey, ADefault);
  finally
    FLock.Leave;
  end;
end;

function TConfig.GetInt(const ASection, AKey: string; ADefault: Integer): Integer;
begin
  Result := StrToIntDef(Trim(GetString(ASection, AKey, IntToStr(ADefault))), ADefault);
end;

function TConfig.GetInt64(const ASection, AKey: string; ADefault: Int64): Int64;
begin
  Result := StrToInt64Def(Trim(GetString(ASection, AKey, IntToStr(ADefault))), ADefault);
end;

function TConfig.GetBool(const ASection, AKey: string; ADefault: Boolean): Boolean;
var
  s: string;
begin
  s := LowerCase(Trim(GetString(ASection, AKey, '')));
  if s = '' then
    Exit(ADefault);
  Result := (s = '1') or (s = 'true') or (s = 'yes') or (s = 'on');
end;

function TConfig.GetFloat(const ASection, AKey: string; ADefault: Double): Double;
var
  s: string;
  fs: TFormatSettings;
begin
  s := Trim(GetString(ASection, AKey, ''));
  if s = '' then
    Exit(ADefault);
  fs := InvariantFS;
  if not TryStrToFloat(s, Result, fs) then
    Result := ADefault;
end;

procedure TConfig.SetString(const ASection, AKey, AValue: string);
begin
  FLock.Enter;
  try
    FIni.WriteString(ASection, AKey, AValue);
    FDirty := True;
  finally
    FLock.Leave;
  end;
end;

procedure TConfig.SetInt(const ASection, AKey: string; AValue: Integer);
begin
  SetString(ASection, AKey, IntToStr(AValue));
end;

procedure TConfig.SetInt64(const ASection, AKey: string; AValue: Int64);
begin
  SetString(ASection, AKey, IntToStr(AValue));
end;

procedure TConfig.SetBool(const ASection, AKey: string; AValue: Boolean);
begin
  if AValue then
    SetString(ASection, AKey, '1')
  else
    SetString(ASection, AKey, '0');
end;

procedure TConfig.SetFloat(const ASection, AKey: string; AValue: Double);
var
  fs: TFormatSettings;
begin
  fs := InvariantFS;
  SetString(ASection, AKey, FloatToStr(AValue, fs));
end;

procedure TConfig.DeleteKey(const ASection, AKey: string);
begin
  FLock.Enter;
  try
    FIni.DeleteKey(ASection, AKey);
    FDirty := True;
  finally
    FLock.Leave;
  end;
end;

procedure TConfig.Sections(ADest: TStrings);
begin
  FLock.Enter;
  try
    FIni.ReadSections(ADest);
  finally
    FLock.Leave;
  end;
end;

end.
