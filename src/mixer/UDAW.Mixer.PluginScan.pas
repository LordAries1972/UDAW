unit UDAW.Mixer.PluginScan;
{$I udaw.inc}

{ Plug-in discovery for the effect hosts (VST2 .dll, VST3 .vst3).

  Scan walks the plug-in folders, pre-filters .dll files by their export table
  (LoadLibraryEx with DONT_RESOLVE_DLL_REFERENCES - no DllMain, no dependencies
  loaded) so unrelated DLLs are never initialised, then identifies each
  candidate with the same LoadOnly probe the hosts use when a plug-in is
  inserted. Results are cached by file size + timestamp so a rescan only
  re-probes what changed. The scan reports per-candidate progress through a
  callback; the caller shows it on the status bar. }

interface

uses
  Windows, SysUtils, Classes, Generics.Collections, Generics.Defaults;

type
  TPluginFormat = (pfVST2, pfVST3);

  TScannedPlugin = record
    Format: TPluginFormat;
    Path: string;
    Name: string;
    Vendor: string;
    Stamp: string;   // "<size>:<filetime>" - cache validity key
  end;

  { ADone of ATotal candidates probed; ACurrent is the file being probed. }
  TPluginScanProgress = reference to procedure(ADone, ATotal: Integer; const ACurrent: string);

  TPluginScanner = class
  private
    FPlugins: TList<TScannedPlugin>;
    FRoots: TStringList;
    FSkipped: Integer;
    FLastErrors: TStringList;
    procedure CollectCandidates(const ARoot: string; AOut: TStrings);
    function HasVst2Export(const APath: string): Boolean;
    class function StampOf(const APath: string): string;
    function FindCached(const APath, AStamp: string; out AIdx: Integer): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddDefaultRoots;
    procedure AddRoot(const AFolder: string);
    function Scan(const AProgress: TPluginScanProgress): Integer;
    function Count: Integer;
    function Item(AIndex: Integer): TScannedPlugin;
    procedure LoadFromFile(const AFileName: string);
    procedure SaveToFile(const AFileName: string);
    property Roots: TStringList read FRoots;
    property Skipped: Integer read FSkipped;     // candidates that were not usable effects
    property LastErrors: TStringList read FLastErrors;
  end;

implementation

uses
  UDAW.Mixer.VST2, UDAW.Mixer.VST3;

const
  CACHE_HEADER = 'UDAW-PLUGINS 1';

constructor TPluginScanner.Create;
begin
  inherited Create;
  FPlugins := TList<TScannedPlugin>.Create;
  FRoots := TStringList.Create;
  FRoots.CaseSensitive := False;
  FRoots.Duplicates := dupIgnore;
  FRoots.Sorted := True;
  FLastErrors := TStringList.Create;
end;

destructor TPluginScanner.Destroy;
begin
  FLastErrors.Free;
  FRoots.Free;
  FPlugins.Free;
  inherited Destroy;
end;

procedure TPluginScanner.AddRoot(const AFolder: string);
begin
  if (Trim(AFolder) <> '') and DirectoryExists(AFolder) then
    FRoots.Add(ExcludeTrailingPathDelimiter(AFolder));
end;

procedure TPluginScanner.AddDefaultRoots;
  function Env(const AName: string): string;
  begin
    Result := GetEnvironmentVariable(AName);
  end;
var
  pf, cf, la: string;
begin
  pf := Env('ProgramFiles');
  cf := Env('CommonProgramFiles');
  la := Env('LOCALAPPDATA');
  if cf <> '' then
  begin
    AddRoot(IncludeTrailingPathDelimiter(cf) + 'VST3');
    AddRoot(IncludeTrailingPathDelimiter(cf) + 'VST2');
  end;
  if la <> '' then
    AddRoot(IncludeTrailingPathDelimiter(la) + 'Programs\Common\VST3');
  if pf <> '' then
  begin
    AddRoot(IncludeTrailingPathDelimiter(pf) + 'VSTPlugins');
    AddRoot(IncludeTrailingPathDelimiter(pf) + 'Steinberg\VSTPlugins');
    AddRoot(IncludeTrailingPathDelimiter(pf) + 'Steinberg\VST3');
  end;
end;

{ A VST2 plug-in DLL exports VSTPluginMain (or the legacy "main"). The DLL is
  mapped without running DllMain or resolving imports, so this is safe on any
  DLL. }
function TPluginScanner.HasVst2Export(const APath: string): Boolean;
var
  h: HMODULE;
begin
  Result := False;
  h := LoadLibraryEx(PChar(APath), 0, DONT_RESOLVE_DLL_REFERENCES);
  if h = 0 then Exit;
  try
    Result := (GetProcAddress(h, 'VSTPluginMain') <> nil) or (GetProcAddress(h, 'main') <> nil);
  finally
    FreeLibrary(h);
  end;
end;

class function TPluginScanner.StampOf(const APath: string): string;
var
  sr: TSearchRec;
begin
  Result := '';
  if FindFirst(APath, faAnyFile, sr) = 0 then
  begin
    try
      Result := Format('%d:%d', [sr.Size, Round(sr.TimeStamp * 86400)]);
    finally
      FindClose(sr);
    end;
  end;
end;

{ .vst3 entries are files or bundle folders - never descend into a bundle. }
procedure TPluginScanner.CollectCandidates(const ARoot: string; AOut: TStrings);
var
  sr: TSearchRec;
  dir, full, ext: string;
begin
  dir := IncludeTrailingPathDelimiter(ARoot);
  if FindFirst(dir + '*', faAnyFile, sr) <> 0 then Exit;
  try
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      full := dir + sr.Name;
      ext := LowerCase(ExtractFileExt(sr.Name));
      if ext = '.vst3' then
        AOut.Add(full)
      else if (sr.Attr and faDirectory) <> 0 then
        CollectCandidates(full, AOut)
      else if ext = '.dll' then
        AOut.Add(full);
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

function TPluginScanner.FindCached(const APath, AStamp: string; out AIdx: Integer): Boolean;
var
  i: Integer;
begin
  for i := 0 to FPlugins.Count - 1 do
    if SameText(FPlugins[i].Path, APath) then
    begin
      AIdx := i;
      Exit(FPlugins[i].Stamp = AStamp);
    end;
  AIdx := -1;
  Result := False;
end;

function TPluginScanner.Scan(const AProgress: TPluginScanProgress): Integer;
var
  cands: TStringList;
  keep: TList<TScannedPlugin>;
  r, i, idx: Integer;
  p: TScannedPlugin;
  stamp, ext: string;
  v2: TVST2Host;
  v3: TVST3Host;
begin
  FSkipped := 0;
  FLastErrors.Clear;
  cands := TStringList.Create;
  keep := TList<TScannedPlugin>.Create;
  try
    cands.CaseSensitive := False;
    cands.Sorted := True;
    cands.Duplicates := dupIgnore;
    for r := 0 to FRoots.Count - 1 do
      CollectCandidates(FRoots[r], cands);

    for i := 0 to cands.Count - 1 do
    begin
      if Assigned(AProgress) then AProgress(i, cands.Count, ExtractFileName(cands[i]));
      ext := LowerCase(ExtractFileExt(cands[i]));
      stamp := StampOf(cands[i]);
      if FindCached(cands[i], stamp, idx) then
      begin
        keep.Add(FPlugins[idx]);
        Continue;
      end;
      if (ext = '.dll') and not HasVst2Export(cands[i]) then Continue;   // not a plug-in at all

      p.Path := cands[i];
      p.Stamp := stamp;
      p.Vendor := '';
      try
        if ext = '.vst3' then
        begin
          p.Format := pfVST3;
          v3 := TVST3Host.Create;
          try
            v3.LoadOnly(cands[i]);
            p.Name := v3.EffectName;
            p.Vendor := v3.VendorString;
          finally
            v3.Free;
          end;
        end
        else
        begin
          p.Format := pfVST2;
          v2 := TVST2Host.Create;
          try
            v2.LoadOnly(cands[i]);
            p.Name := v2.EffectName;
            p.Vendor := v2.VendorString;
          finally
            v2.Free;
          end;
        end;
        if p.Name = '' then p.Name := ChangeFileExt(ExtractFileName(cands[i]), '');
        keep.Add(p);
      except
        on E: Exception do
        begin
          Inc(FSkipped);
          FLastErrors.Add(ExtractFileName(cands[i]) + ': ' + E.Message);
        end;
      end;
    end;
    if Assigned(AProgress) then AProgress(cands.Count, cands.Count, '');

    FPlugins.Clear;
    FPlugins.AddRange(keep);
    FPlugins.Sort(TComparer<TScannedPlugin>.Construct(
      function(const A, B: TScannedPlugin): Integer
      begin
        Result := CompareText(A.Name, B.Name);
      end));
    Result := FPlugins.Count;
  finally
    keep.Free;
    cands.Free;
  end;
end;

function TPluginScanner.Count: Integer;
begin
  Result := FPlugins.Count;
end;

function TPluginScanner.Item(AIndex: Integer): TScannedPlugin;
begin
  Result := FPlugins[AIndex];
end;

procedure TPluginScanner.SaveToFile(const AFileName: string);
var
  sl: TStringList;
  i: Integer;
  p: TScannedPlugin;
begin
  sl := TStringList.Create;
  try
    sl.Add(CACHE_HEADER);
    for i := 0 to FRoots.Count - 1 do
      sl.Add('R'#9 + FRoots[i]);
    for i := 0 to FPlugins.Count - 1 do
    begin
      p := FPlugins[i];
      sl.Add(Format('P'#9'%d'#9'%s'#9'%s'#9'%s'#9'%s', [Ord(p.Format), p.Path, p.Name, p.Vendor, p.Stamp]));
    end;
    ForceDirectories(ExtractFilePath(AFileName));
    sl.SaveToFile(AFileName, TEncoding.UTF8);
  finally
    sl.Free;
  end;
end;

procedure TPluginScanner.LoadFromFile(const AFileName: string);
var
  sl: TStringList;
  i: Integer;
  f: TArray<string>;
  p: TScannedPlugin;
begin
  FPlugins.Clear;
  if not FileExists(AFileName) then Exit;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(AFileName, TEncoding.UTF8);
    if (sl.Count = 0) or (sl[0] <> CACHE_HEADER) then Exit;
    for i := 1 to sl.Count - 1 do
    begin
      f := sl[i].Split([#9]);
      if (Length(f) = 2) and (f[0] = 'R') then
        AddRoot(f[1])
      else if (Length(f) = 6) and (f[0] = 'P') then
      begin
        p.Format := TPluginFormat(StrToIntDef(f[1], 0) and 1);
        p.Path := f[2];
        p.Name := f[3];
        p.Vendor := f[4];
        p.Stamp := f[5];
        if FileExists(p.Path) or DirectoryExists(p.Path) then FPlugins.Add(p);
      end;
    end;
  finally
    sl.Free;
  end;
end;

end.
