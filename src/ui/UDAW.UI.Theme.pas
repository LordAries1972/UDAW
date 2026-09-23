unit UDAW.UI.Theme;
{$I udaw.inc}

{ Visual themes (VCL styles).

  UDAW ships a set of .vsf style files under resources/styles/.  This unit
  discovers them, registers them with the Delphi VCL TStyleManager at start-up,
  applies the one saved in config ([ui] theme) and lets the Settings tab switch
  live and persist the choice.

  VCL styles are a Delphi-only feature - under FPC/Lazarus every routine here is
  a no-op and ThemeAvailable returns just the built-in look, so the shared UI
  code compiles and runs on both toolchains (Linux/macOS theming is the
  widgetset's job). }

interface

uses
  SysUtils, Classes,
  UDAW.Config;

const
  CFG_SEC_UI   = 'ui';
  CFG_UI_THEME = 'theme';
  THEME_DEFAULT = 'Windows';        // the built-in, un-styled VCL look

{ Scan the style folders and register every .vsf found.  Safe to call once at
  start-up; repeated calls are cheap no-ops for already-registered styles. }
procedure ThemeLoadStyles;

{ All selectable style names: THEME_DEFAULT first, then the loaded .vsf styles
  sorted alphabetically. }
function ThemeAvailable: TArray<string>;

{ The style currently in effect (THEME_DEFAULT when unstyled). }
function ThemeCurrent: string;

{ Switch the active style now.  Returns False if the name is unknown. }
function ThemeApply(const AName: string): Boolean;

{ Load the styles, then apply the one in ACfg ([ui] theme).  Call once from the
  program file after the config is available and before the main form is made. }
procedure ThemeInitFromConfig(ACfg: TConfig);

{ Read only the saved style before creating the startup splash. }
procedure ThemeInitForStartup;

{ Persist AName as the start-up theme in ACfg (does not Save). }
procedure ThemeSaveToConfig(ACfg: TConfig; const AName: string);

{ The directory the .vsf files were loaded from (for display), '' if none. }
function ThemeStylesDir: string;

implementation

uses IniFiles, UDAW.Paths
  {$IFNDEF FPC}, IOUtils, Vcl.Themes, Vcl.Styles{$ENDIF};


var
  GStylesDir: string = '';
  GLoaded: Boolean = False;

{ candidate locations, in priority order, for the resources/styles folder }
function CandidateStyleDirs: TArray<string>;
var
  exeDir, cwd: string;
begin
  exeDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  cwd := IncludeTrailingPathDelimiter(GetCurrentDir);
  Result := [
    exeDir + 'resources' + PathDelim + 'styles' + PathDelim,
    exeDir + '..' + PathDelim + '..' + PathDelim + 'resources' + PathDelim + 'styles' + PathDelim,
    exeDir + '..' + PathDelim + '..' + PathDelim + '..' + PathDelim + 'resources' + PathDelim + 'styles' + PathDelim,
    cwd + 'resources' + PathDelim + 'styles' + PathDelim
  ];
end;

function FirstExistingStyleDir: string;
var
  d: string;
begin
  for d in CandidateStyleDirs do
    if DirectoryExists(d) then Exit(d);
  Result := '';
end;

function ThemeStylesDir: string;
begin
  Result := GStylesDir;
end;

{$IFDEF FPC}

procedure ThemeLoadStyles;
begin
  GLoaded := True;
  GStylesDir := FirstExistingStyleDir;
end;

function ThemeAvailable: TArray<string>;
begin
  Result := [THEME_DEFAULT];
end;

function ThemeCurrent: string;
begin
  Result := THEME_DEFAULT;
end;

function ThemeApply(const AName: string): Boolean;
begin
  Result := SameText(AName, THEME_DEFAULT);
end;

{$ELSE}

{ TStyleManager.StyleNames is a TArray<string>, not a TStrings - no .IndexOf. }
function StyleIsRegistered(const AName: string): Boolean;
var
  s: string;
begin
  Result := False;
  for s in TStyleManager.StyleNames do
    if SameText(s, AName) then Exit(True);
end;

procedure ThemeLoadStyles;
var
  dir, fn: string;
  info: TStyleInfo;
begin
  if GLoaded then Exit;
  GLoaded := True;
  dir := FirstExistingStyleDir;
  GStylesDir := dir;
  if dir = '' then Exit;
  for fn in TDirectory.GetFiles(dir, '*.vsf') do
  begin
    try
      if TStyleManager.IsValidStyle(fn, info) then
        if not StyleIsRegistered(info.Name) then
          TStyleManager.LoadFromFile(fn);
    except
      { a corrupt / incompatible .vsf must not stop start-up }
    end;
  end;
end;

function ThemeAvailable: TArray<string>;
var
  names: TStringList;
  s: string;
begin
  names := TStringList.Create;
  try
    names.Duplicates := dupIgnore;
    names.Sorted := True;
    for s in TStyleManager.StyleNames do
      if not SameText(s, THEME_DEFAULT) then
        names.Add(s);
    Result := [THEME_DEFAULT];
    for s in names do
      Result := Result + [s];
  finally
    names.Free;
  end;
end;

function ThemeCurrent: string;
begin
  if TStyleManager.ActiveStyle <> nil then
    Result := TStyleManager.ActiveStyle.Name
  else
    Result := THEME_DEFAULT;
  if Result = '' then Result := THEME_DEFAULT;
end;

function ThemeApply(const AName: string): Boolean;
var
  s: string;
begin
  Result := False;
  if (AName = '') or SameText(AName, THEME_DEFAULT) then
  begin
    TStyleManager.SetStyle(THEME_DEFAULT);
    Exit(True);
  end;
  for s in TStyleManager.StyleNames do
    if SameText(s, AName) then
    begin
      TStyleManager.SetStyle(s);
      Exit(True);
    end;
end;

{$ENDIF}

procedure ThemeInitFromConfig(ACfg: TConfig);
var
  want: string;
begin
  ThemeLoadStyles;
  if ACfg = nil then Exit;
  want := ACfg.GetString(CFG_SEC_UI, CFG_UI_THEME, THEME_DEFAULT);
  if (want <> '') and not SameText(want, THEME_DEFAULT) then
    ThemeApply(want);
end;

procedure ThemeInitForStartup;
var ini: TMemIniFile; name: string;
begin
  ThemeLoadStyles;
  ini := TMemIniFile.Create(ConfigFile('udaw.ini'));
  try
    name := ini.ReadString(CFG_SEC_UI, CFG_UI_THEME, THEME_DEFAULT);
    if not ThemeApply(name) then ThemeApply(THEME_DEFAULT);
  finally ini.Free; end;
end;

procedure ThemeSaveToConfig(ACfg: TConfig; const AName: string);
begin
  if ACfg = nil then Exit;
  if (AName = '') then
    ACfg.SetString(CFG_SEC_UI, CFG_UI_THEME, THEME_DEFAULT)
  else
    ACfg.SetString(CFG_SEC_UI, CFG_UI_THEME, AName);
end;

end.
