unit Tests.Phase33;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}

{ Phase 33 acceptance tests - AI Composition Phase 2 (docs/AIPlan.md section
  17 Phase 2: Browser + instrument catalogue). Builds a scratch temp
  directory tree so ScanRoots/TextSearch/FindByTag/FindByRole/MarkMissing/
  SaveToFile/LoadFromFile can be exercised against real files without
  touching the user's actual libraries. No real VST binary is available for
  automated testing, so .dll classification is checked only by extension
  (Kind = ikInstrumentVST), matching how Phase 20 left UDAW.AI.HTTP's real
  network calls untested for the same "needs a real endpoint" reason. }

interface

procedure RegisterPhase33Tests;

implementation

uses
  SysUtils, Classes,
  UDAW.Testing,
  UDAW.Paths,
  UDAW.AI.JSON,
  UDAW.Browser.Catalogue;

const
  GRP = 'phase33.browser_catalogue';

function MakeScratchTree: string;
var
  root: string;
begin
  root := IncludeTrailingPathDelimiter(Paths.Temp) +
    FormatDateTime('yyyymmdd-hhnnsszzz', Now) + '-' + IntToStr(Random(100000)) + PathDelim;
  ForceDirectories(root);
  ForceDirectories(IncludeTrailingPathDelimiter(root) + 'Loops');
  ForceDirectories(IncludeTrailingPathDelimiter(root) + 'DrumKits');
  ForceDirectories(IncludeTrailingPathDelimiter(root) + 'Vocals');

  with TStringList.Create do
  try
    Text := 'not real audio, just needs to exist for a file-based scan';
    SaveToFile(IncludeTrailingPathDelimiter(root) + 'Loops\dark_techno_loop.wav');
    SaveToFile(IncludeTrailingPathDelimiter(root) + 'DrumKits\punchy_kick.wav');
    SaveToFile(IncludeTrailingPathDelimiter(root) + 'Vocals\female_vocal_take.wav');
    SaveToFile(IncludeTrailingPathDelimiter(root) + 'analog_bass.sf2');
    SaveToFile(IncludeTrailingPathDelimiter(root) + 'SomePlugin.dll');
  finally
    Free;
  end;
  Result := root;
end;

procedure DeleteTreeRecursive(const APath: string);
var
  sr: TSearchRec;
  full: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, sr) = 0 then
  try
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      full := IncludeTrailingPathDelimiter(APath) + sr.Name;
      if (sr.Attr and faDirectory) <> 0 then
        DeleteTreeRecursive(full)
      else
        DeleteFile(full);
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
  RemoveDir(APath);
end;

procedure DeleteScratchTree(const ARoot: string);
begin
  if (ARoot <> '') and DirectoryExists(ARoot) then
    DeleteTreeRecursive(ARoot);
end;

procedure Test_ScanRoots_ClassifiesAndTags;
var
  root: string;
  cat: TInstrumentCatalogue;
  loopHits, kitHits, vocalHits, sfHits, vstHits: TArray<TCatalogueItem>;
begin
  root := MakeScratchTree;
  cat := TInstrumentCatalogue.Create;
  try
    cat.ScanRoots([root]);
    Check(cat.ItemCount = 5, 'all five scratch files are catalogued');

    loopHits := cat.FindByTag('loop');
    Check(Length(loopHits) = 1, 'the Loops-folder wav is tagged "loop"');
    Check(loopHits[0].Kind = ikLoop, 'the Loops-folder wav classifies as ikLoop');

    kitHits := cat.FindByCategory('Drum Kits');
    Check(Length(kitHits) = 1, 'the DrumKits-folder wav classifies as a drum kit');

    vocalHits := cat.FindByRole('vocal');
    Check(Length(vocalHits) >= 1, 'the Vocals-folder wav is role-tagged "vocal"');

    sfHits := cat.FindByCategory('Instruments');
    Check(Length(sfHits) >= 1, 'the .sf2 file lands in the Instruments category');

    vstHits := cat.TextSearch('someplugin');
    Check(Length(vstHits) = 1, 'the .dll is found by name search');
    Check(vstHits[0].Kind = ikInstrumentVST, '.dll classifies as ikInstrumentVST by extension');
  finally
    cat.Free;
    DeleteScratchTree(root);
  end;
end;

procedure Test_StableId_SurvivesRescans;
var
  root: string;
  cat: TInstrumentCatalogue;
  idFirst, idSecond: string;
begin
  root := MakeScratchTree;
  cat := TInstrumentCatalogue.Create;
  try
    cat.ScanRoots([root]);
    idFirst := cat.ItemById(StableCatalogueId(IncludeTrailingPathDelimiter(root) + 'analog_bass.sf2')).Id;
    cat.Clear;
    cat.ScanRoots([root]);
    idSecond := cat.ItemById(StableCatalogueId(IncludeTrailingPathDelimiter(root) + 'analog_bass.sf2')).Id;
    CheckEqualStr(idFirst, idSecond, 'the same file gets the same stable id across two scans');
  finally
    cat.Free;
    DeleteScratchTree(root);
  end;
end;

procedure Test_MarkMissing_NeverRemoves;
var
  root: string;
  cat: TInstrumentCatalogue;
  countBefore: Integer;
  bassId: string;
begin
  root := MakeScratchTree;
  cat := TInstrumentCatalogue.Create;
  try
    cat.ScanRoots([root]);
    countBefore := cat.ItemCount;
    bassId := StableCatalogueId(IncludeTrailingPathDelimiter(root) + 'analog_bass.sf2');
    DeleteFile(IncludeTrailingPathDelimiter(root) + 'analog_bass.sf2');

    cat.MarkMissing;
    CheckEqualInt(countBefore, cat.ItemCount, 'MarkMissing never removes an item');
    CheckFalse(cat.ItemById(bassId).Available, 'the deleted file''s item is marked unavailable');
  finally
    cat.Free;
    DeleteScratchTree(root);
  end;
end;

procedure Test_SaveLoad_RoundTrips;
var
  root, jsonPath: string;
  cat, cat2: TInstrumentCatalogue;
begin
  root := MakeScratchTree;
  jsonPath := IncludeTrailingPathDelimiter(Paths.Temp) + 'udaw_test_catalogue.json';
  cat := TInstrumentCatalogue.Create;
  cat2 := TInstrumentCatalogue.Create;
  try
    cat.ScanRoots([root]);
    cat.SaveToFile(jsonPath);

    cat2.LoadFromFile(jsonPath);
    CheckEqualInt(cat.ItemCount, cat2.ItemCount, 'item count round-trips through JSON');
    CheckEqualStr(cat.GetItem(0).Id, cat2.GetItem(0).Id, 'item id round-trips');
    CheckEqualStr(cat.GetItem(0).Path, cat2.GetItem(0).Path, 'item path round-trips (internal only, never in SafeDescription)');
  finally
    cat2.Free;
    cat.Free;
    DeleteScratchTree(root);
    if FileExists(jsonPath) then DeleteFile(jsonPath);
  end;
end;

procedure Test_SafeDescription_NeverIncludesPath;
var
  root: string;
  cat: TInstrumentCatalogue;
  desc: string;
  json: TJSONValue;
begin
  root := MakeScratchTree;
  cat := TInstrumentCatalogue.Create;
  try
    cat.ScanRoots([root]);
    json := cat.SafeDescriptionJSON(cat.GetItem(0));
    try
      desc := json.ToJSONString;
      Check(Pos(root, desc) = 0, 'SafeDescriptionJSON never includes the item''s filesystem path');
      Check(Pos('"id"', desc) > 0, 'SafeDescriptionJSON includes id');
      Check(Pos('"available"', desc) > 0, 'SafeDescriptionJSON includes available');
    finally
      json.Free;
    end;
  finally
    cat.Free;
    DeleteScratchTree(root);
  end;
end;

procedure RegisterPhase33Tests;
begin
  RegisterTest(GRP, 'ScanRoots classifies and tags every scratch file', Test_ScanRoots_ClassifiesAndTags);
  RegisterTest(GRP, 'Stable id survives a rescan of the same tree', Test_StableId_SurvivesRescans);
  RegisterTest(GRP, 'MarkMissing marks unavailable but never removes', Test_MarkMissing_NeverRemoves);
  RegisterTest(GRP, 'SaveToFile/LoadFromFile round-trip losslessly', Test_SaveLoad_RoundTrips);
  RegisterTest(GRP, 'SafeDescriptionJSON never leaks the filesystem path', Test_SafeDescription_NeverIncludesPath);
end;

end.
