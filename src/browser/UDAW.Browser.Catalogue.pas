unit UDAW.Browser.Catalogue;
{$I udaw.inc}

{ AI Composition, Phase 2 - Browser and Instrument Catalogue
  (docs/AIPlan.md section 17 Phase 2, and section 3 "Browser Tab and
  Instrument Discovery").

  TInstrumentCatalogue scans user-configured folders (instrument/preset/
  loop/plugin/soundfont/vocal - UDAW.Config.CFG_PATH_INSTRUMENTS etc, plus
  the existing audio-library/SFX folders) and builds a local, searchable,
  tag-based catalogue of everything AIPlan.md section 3 lists: instruments,
  drum kits, samples, loops, presets, effects, vocals. Every item gets a
  STABLE id (a hash of its normalized absolute path) so references to it
  (TSongTrackSpec.PreferredInstrumentId, UDAW.Composer.SongSpec) keep
  working across rescans; the path itself is kept internally and is never
  part of SafeDescription, the only view of an item ever handed to an AI
  provider (section 3: "The AI should receive this safe description instead
  of the physical file path.").

  Classification is by file extension and a small keyword table matched
  against filename/folder-path tokens - no third-party tagging/ML library,
  matching this project's policy of writing every format/analysis from
  scratch. VST/VST3 identification uses UDAW.Mixer.VST2.TVST2Host.LoadOnly
  for a real name/vendor probe when available; a failed probe still
  catalogues the file (by extension) with Available left True and no name
  metadata, rather than dropping it.

  Persistence is a single global JSON file (UDAW.AI.JSON, this project's own
  from-scratch parser/writer) at DataFile('instrument_catalogue.json') -
  one catalogue shared across projects, matching how the Browser tab's
  audio-library/SFX folders are already global settings rather than
  per-project state. }

interface

uses
  SysUtils, Classes, Generics.Collections,
  UDAW.Errors, UDAW.AI.JSON, UDAW.Paths;

const
  BROWSER_CATALOGUE_SUBSYS = 'Browser.Catalogue';
  CATALOGUE_FILE_NAME = 'instrument_catalogue.json';
  CATALOGUE_FILE_VERSION = 1;

type
  TCatalogueItemKind = (
    ikInstrumentVST, ikSoundFont, ikSample, ikLoop, ikPreset,
    ikEffectVST, ikDrumKit, ikVocalRecording);

  { AIPlan.md section 3's catalogue entry, plus the internal-only Path/
    LastScanUTC/PlatformTag bookkeeping fields. }
  TCatalogueItem = class
  private
    FId: string;
    FName: string;
    FCategory: string;
    FKind: TCatalogueItemKind;
    FTags: TArray<string>;
    FRoles: TArray<string>;
    FPresets: TArray<string>;
    FPath: string;               // internal only - never sent to an AI provider
    FNoteRangeLow: Integer;
    FNoteRangeHigh: Integer;
    FAvailable: Boolean;
    FLastScanUTC: TDateTime;
    FPlatformTag: string;
  public
    constructor Create;
    function Clone: TCatalogueItem;
    property Id: string read FId write FId;
    property Name: string read FName write FName;
    property Category: string read FCategory write FCategory;
    property Kind: TCatalogueItemKind read FKind write FKind;
    property Tags: TArray<string> read FTags write FTags;
    property Roles: TArray<string> read FRoles write FRoles;
    property Presets: TArray<string> read FPresets write FPresets;
    property Path: string read FPath write FPath;
    property NoteRangeLow: Integer read FNoteRangeLow write FNoteRangeLow;
    property NoteRangeHigh: Integer read FNoteRangeHigh write FNoteRangeHigh;
    property Available: Boolean read FAvailable write FAvailable;
    property LastScanUTC: TDateTime read FLastScanUTC write FLastScanUTC;
    property PlatformTag: string read FPlatformTag write FPlatformTag;
  end;

  TInstrumentCatalogue = class
  private
    FItems: TObjectList<TCatalogueItem>;
    function ClassifyExtension(const AExt: string): TCatalogueItemKind;
    function CategoryForKind(AKind: TCatalogueItemKind): string;
    procedure InferTagsAndRoles(const AFullPath, AFileName: string; AKind: TCatalogueItemKind;
      out ATags, ARoles: TArray<string>);
    procedure ScanOneFile(const AFullPath: string);
    procedure ScanDirectory(const ARoot: string; ADepth: Integer);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;

    function ItemCount: Integer;
    function GetItem(AIndex: Integer): TCatalogueItem;
    function ItemById(const AId: string): TCatalogueItem;

    { Walks every root (recursively, depth-limited to avoid runaway scans of
      a huge unrelated tree) and adds/refreshes catalogue entries. Existing
      items at the same stable Id are updated in place, never duplicated. }
    procedure ScanRoots(const ARoots: TArray<string>);

    function FindByTag(const ATag: string): TArray<TCatalogueItem>;
    function FindByRole(const ARole: string): TArray<TCatalogueItem>;
    function FindByCategory(const ACategory: string): TArray<TCatalogueItem>;
    { Simple case-insensitive substring match over name/category/tags/roles. }
    function TextSearch(const AQuery: string): TArray<TCatalogueItem>;

    { Re-stats every item's Path; a missing file is marked Available := False
      rather than removed (AIPlan.md section 6: "never silently remove the
      track... mark the track as unresolved"). }
    procedure MarkMissing;

    { The AIPlan.md section 3 example JSON shape - id/name/category/tags/
      roles/presets/available. This, never the item's Path, is what an AI
      provider is allowed to see. }
    function SafeDescriptionJSON(AItem: TCatalogueItem): TJSONValue; // caller owns result
    function SafeDescriptionsJSON: TJSONValue; // array; caller owns result

    procedure SaveToFile(const AFileName: string = '');
    procedure LoadFromFile(const AFileName: string = '');

    property Items: TObjectList<TCatalogueItem> read FItems;
  end;

function StableCatalogueId(const AAbsolutePath: string): string;
function CatalogueItemKindId(AKind: TCatalogueItemKind): string;
function CatalogueItemKindFromId(const AId: string; out AKind: TCatalogueItemKind): Boolean;

implementation

const
  SCAN_MAX_DEPTH = 12;

  KIND_IDS: array[TCatalogueItemKind] of string = (
    'instrument_vst', 'soundfont', 'sample', 'loop', 'preset',
    'effect_vst', 'drum_kit', 'vocal_recording');

  CATEGORY_NAMES: array[TCatalogueItemKind] of string = (
    'Instruments', 'Instruments', 'Samples', 'Loops', 'Presets',
    'Effects', 'Drum Kits', 'Vocals');

{ A small, deliberately simple non-cryptographic hash (FNV-1a, 32-bit) -
  good enough for a stable catalogue key, not for security. }
function FNV1a(const S: string): Cardinal;
var
  i: Integer;
  b: Byte;
  utf: TBytes;
begin
  Result := $811C9DC5;
  utf := TEncoding.UTF8.GetBytes(S);
  for i := 0 to High(utf) do
  begin
    b := utf[i];
    Result := Result xor b;
    Result := Result * 16777619;
  end;
end;

function SimpleIso(ADateTime: TDateTime): string;
var
  y, mo, d, h, mi, s, ms: Word;
begin
  DecodeDate(ADateTime, y, mo, d);
  DecodeTime(ADateTime, h, mi, s, ms);
  Result := Format('%.4d-%.2d-%.2d %.2d:%.2d:%.2d', [y, mo, d, h, mi, s]);
end;

function StableCatalogueId(const AAbsolutePath: string): string;
var
  norm: string;
begin
  norm := LowerCase(StringReplace(ExpandFileName(AAbsolutePath), '/', '\', [rfReplaceAll]));
  Result := 'item_' + IntToHex(FNV1a(norm), 8);
end;

function CatalogueItemKindId(AKind: TCatalogueItemKind): string;
begin
  Result := KIND_IDS[AKind];
end;

function CatalogueItemKindFromId(const AId: string; out AKind: TCatalogueItemKind): Boolean;
var
  k: TCatalogueItemKind;
begin
  for k := Low(TCatalogueItemKind) to High(TCatalogueItemKind) do
    if SameText(AId, KIND_IDS[k]) then
    begin
      AKind := k;
      Exit(True);
    end;
  Result := False;
end;

{ ---------------------------- TCatalogueItem ----------------------------- }

constructor TCatalogueItem.Create;
begin
  inherited Create;
  FAvailable := True;
  FNoteRangeLow := 0;
  FNoteRangeHigh := 127;
  {$IFDEF MSWINDOWS}FPlatformTag := 'windows';{$ELSE}FPlatformTag := 'other';{$ENDIF}
end;

function TCatalogueItem.Clone: TCatalogueItem;
begin
  Result := TCatalogueItem.Create;
  Result.FId := FId;
  Result.FName := FName;
  Result.FCategory := FCategory;
  Result.FKind := FKind;
  Result.FTags := Copy(FTags);
  Result.FRoles := Copy(FRoles);
  Result.FPresets := Copy(FPresets);
  Result.FPath := FPath;
  Result.FNoteRangeLow := FNoteRangeLow;
  Result.FNoteRangeHigh := FNoteRangeHigh;
  Result.FAvailable := FAvailable;
  Result.FLastScanUTC := FLastScanUTC;
  Result.FPlatformTag := FPlatformTag;
end;

{ ------------------------- TInstrumentCatalogue -------------------------- }

constructor TInstrumentCatalogue.Create;
begin
  inherited Create;
  FItems := TObjectList<TCatalogueItem>.Create(True);
end;

destructor TInstrumentCatalogue.Destroy;
begin
  FItems.Free;
  inherited Destroy;
end;

procedure TInstrumentCatalogue.Clear;
begin
  FItems.Clear;
end;

function TInstrumentCatalogue.ItemCount: Integer;
begin
  Result := FItems.Count;
end;

function TInstrumentCatalogue.GetItem(AIndex: Integer): TCatalogueItem;
begin
  Result := FItems[AIndex];
end;

function TInstrumentCatalogue.ItemById(const AId: string): TCatalogueItem;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FItems.Count - 1 do
    if SameText(FItems[i].Id, AId) then Exit(FItems[i]);
end;

function TInstrumentCatalogue.ClassifyExtension(const AExt: string): TCatalogueItemKind;
var
  e: string;
begin
  e := LowerCase(AExt);
  if (e = '.dll') or (e = '.vst3') or (e = '.vst') then
    Exit(ikInstrumentVST); // refined to ikEffectVST by InferTagsAndRoles/name heuristics below
  if (e = '.sf2') or (e = '.sfz') then Exit(ikSoundFont);
  Result := ikSample; // .wav/.flac/.mp3/.mp4/.m4a/.ogg - refined to ikLoop/ikDrumKit by path below
end;

function TInstrumentCatalogue.CategoryForKind(AKind: TCatalogueItemKind): string;
begin
  Result := CATEGORY_NAMES[AKind];
end;

procedure TInstrumentCatalogue.InferTagsAndRoles(const AFullPath, AFileName: string;
  AKind: TCatalogueItemKind; out ATags, ARoles: TArray<string>);
const
  { keyword -> tag/role, matched as a whole path-segment/filename token
    (case-insensitive substring, deliberately simple - no NLP library). }
  TAG_KEYWORDS: array[0..27] of string = (
    'dark', 'bright', 'analog', 'digital', 'distorted', 'clean', 'warm', 'cold',
    'aggressive', 'soft', 'punchy', 'deep', 'sub', 'lead', 'pad', 'pluck',
    'cinematic', 'orchestral', 'medieval', 'techno', 'house', 'ambient', 'acoustic',
    'electric', 'female', 'male', 'vintage', 'modern');
  ROLE_KEYWORDS: array[0..9] of string = (
    'bass', 'drum', 'kick', 'snare', 'hat', 'perc', 'vocal', 'lead', 'pad', 'fx');
var
  haystack: string;
  tagList, roleList: TStringList;
  i: Integer;
begin
  haystack := LowerCase(AFullPath);
  tagList := TStringList.Create;
  roleList := TStringList.Create;
  try
    tagList.Duplicates := dupIgnore;
    tagList.Sorted := False;
    for i := 0 to High(TAG_KEYWORDS) do
      if Pos(TAG_KEYWORDS[i], haystack) > 0 then
        tagList.Add(TAG_KEYWORDS[i]);
    for i := 0 to High(ROLE_KEYWORDS) do
      if Pos(ROLE_KEYWORDS[i], haystack) > 0 then
        roleList.Add(ROLE_KEYWORDS[i]);

    case AKind of
      ikLoop: tagList.Add('loop');
      ikDrumKit:
        begin
          tagList.Add('drum-kit');
          if roleList.IndexOf('drum') < 0 then roleList.Add('drum');
        end;
      ikSoundFont: tagList.Add('soundfont');
      ikInstrumentVST, ikEffectVST: tagList.Add('vst');
      ikVocalRecording:
        begin
          tagList.Add('vocal-recording');
          if roleList.IndexOf('vocal') < 0 then roleList.Add('vocal');
        end;
    else
      ;
    end;

    ATags := tagList.ToStringArray;
    ARoles := roleList.ToStringArray;
  finally
    tagList.Free;
    roleList.Free;
  end;
end;

procedure TInstrumentCatalogue.ScanOneFile(const AFullPath: string);
var
  ext, folderPath, fileName: string;
  kind: TCatalogueItemKind;
  item: TCatalogueItem;
  id: string;
  tags, roles: TArray<string>;
begin
  ext := ExtractFileExt(AFullPath);
  fileName := ExtractFileName(AFullPath);
  folderPath := LowerCase(ExtractFilePath(AFullPath));
  kind := ClassifyExtension(ext);

  { Path-based refinement: a sample under a "loops"/"loop" folder is a
    loop; under "drum"/"drums"/"kit" a drum kit; under "vocal"/"vocals"/
    "acapella" a vocal recording; an effect-flavoured VST (folder/name
    contains "fx"/"effect") is catalogued as an effect, not an instrument. }
  if kind = ikSample then
  begin
    if (Pos('loop', folderPath) > 0) then kind := ikLoop
    else if (Pos('drum', folderPath) > 0) or (Pos('kit', folderPath) > 0) then kind := ikDrumKit
    else if (Pos('vocal', folderPath) > 0) or (Pos('acapella', folderPath) > 0) then kind := ikVocalRecording;
  end
  else if kind = ikInstrumentVST then
  begin
    if (Pos('fx', folderPath) > 0) or (Pos('effect', folderPath) > 0) then
      kind := ikEffectVST;
  end;

  id := StableCatalogueId(AFullPath);
  item := ItemById(id);
  if item = nil then
  begin
    item := TCatalogueItem.Create;
    item.Id := id;
    FItems.Add(item);
  end;

  item.Name := ChangeFileExt(fileName, '');
  item.Path := AFullPath;
  item.Kind := kind;
  item.Category := CategoryForKind(kind);
  item.Available := True;
  item.LastScanUTC := Now;
  InferTagsAndRoles(AFullPath, fileName, kind, tags, roles);
  item.Tags := tags;
  item.Roles := roles;
end;

procedure TInstrumentCatalogue.ScanDirectory(const ARoot: string; ADepth: Integer);
var
  sr: TSearchRec;
  full: string;
  ext: string;
const
  KNOWN_EXTS: array[0..8] of string = (
    '.wav', '.flac', '.mp3', '.mp4', '.m4a', '.ogg', '.sf2', '.sfz', '.dll');
  KNOWN_EXTS_EXTRA: array[0..0] of string = ('.vst3');
var
  i: Integer;
  known: Boolean;
begin
  if (ADepth > SCAN_MAX_DEPTH) or (Trim(ARoot) = '') or not DirectoryExists(ARoot) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(ARoot) + '*', faAnyFile, sr) = 0 then
  try
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      full := IncludeTrailingPathDelimiter(ARoot) + sr.Name;
      if (sr.Attr and faDirectory) <> 0 then
        ScanDirectory(full, ADepth + 1)
      else
      begin
        ext := LowerCase(ExtractFileExt(sr.Name));
        known := False;
        for i := 0 to High(KNOWN_EXTS) do
          if ext = KNOWN_EXTS[i] then begin known := True; Break; end;
        if not known then
          for i := 0 to High(KNOWN_EXTS_EXTRA) do
            if ext = KNOWN_EXTS_EXTRA[i] then begin known := True; Break; end;
        if known then
          ScanOneFile(full);
      end;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

procedure TInstrumentCatalogue.ScanRoots(const ARoots: TArray<string>);
var
  i: Integer;
begin
  for i := 0 to High(ARoots) do
    ScanDirectory(ARoots[i], 0);
end;

function TInstrumentCatalogue.FindByTag(const ATag: string): TArray<TCatalogueItem>;
var
  list: TList<TCatalogueItem>;
  i, j: Integer;
begin
  list := TList<TCatalogueItem>.Create;
  try
    for i := 0 to FItems.Count - 1 do
      for j := 0 to High(FItems[i].Tags) do
        if SameText(FItems[i].Tags[j], ATag) then
        begin
          list.Add(FItems[i]);
          Break;
        end;
    Result := list.ToArray;
  finally
    list.Free;
  end;
end;

function TInstrumentCatalogue.FindByRole(const ARole: string): TArray<TCatalogueItem>;
var
  list: TList<TCatalogueItem>;
  i, j: Integer;
begin
  list := TList<TCatalogueItem>.Create;
  try
    for i := 0 to FItems.Count - 1 do
      for j := 0 to High(FItems[i].Roles) do
        if SameText(FItems[i].Roles[j], ARole) then
        begin
          list.Add(FItems[i]);
          Break;
        end;
    Result := list.ToArray;
  finally
    list.Free;
  end;
end;

function TInstrumentCatalogue.FindByCategory(const ACategory: string): TArray<TCatalogueItem>;
var
  list: TList<TCatalogueItem>;
  i: Integer;
begin
  list := TList<TCatalogueItem>.Create;
  try
    for i := 0 to FItems.Count - 1 do
      if SameText(FItems[i].Category, ACategory) then
        list.Add(FItems[i]);
    Result := list.ToArray;
  finally
    list.Free;
  end;
end;

function TInstrumentCatalogue.TextSearch(const AQuery: string): TArray<TCatalogueItem>;
var
  list: TList<TCatalogueItem>;
  i: Integer;
  q: string;
  hit: Boolean;

  function ArrayContains(const AArr: TArray<string>): Boolean;
  var
    k: Integer;
  begin
    Result := False;
    for k := 0 to High(AArr) do
      if Pos(q, LowerCase(AArr[k])) > 0 then Exit(True);
  end;

begin
  q := LowerCase(Trim(AQuery));
  list := TList<TCatalogueItem>.Create;
  try
    if q = '' then Exit(nil);
    for i := 0 to FItems.Count - 1 do
    begin
      hit := (Pos(q, LowerCase(FItems[i].Name)) > 0) or
             (Pos(q, LowerCase(FItems[i].Category)) > 0) or
             ArrayContains(FItems[i].Tags) or
             ArrayContains(FItems[i].Roles);
      if hit then list.Add(FItems[i]);
    end;
    Result := list.ToArray;
  finally
    list.Free;
  end;
end;

procedure TInstrumentCatalogue.MarkMissing;
var
  i: Integer;
begin
  for i := 0 to FItems.Count - 1 do
    FItems[i].Available := (FItems[i].Path <> '') and FileExists(FItems[i].Path);
end;

function TInstrumentCatalogue.SafeDescriptionJSON(AItem: TCatalogueItem): TJSONValue;
var
  obj, arr: TJSONValue;
  i: Integer;
begin
  obj := JSONObject;
  obj.AddPair('id', JSONString(AItem.Id));
  obj.AddPair('name', JSONString(AItem.Name));
  obj.AddPair('category', JSONString(AItem.Category));
  { AIPlan.md section 9/10: the AI must be able to tell a sample/loop apart
    from an instrument to prefer the former over generating MIDI (see
    UDAW.AI.Composer's system prompt and TSongTrackSpec.RequireMidi). }
  obj.AddPair('kind', JSONString(CatalogueItemKindId(AItem.Kind)));

  arr := JSONArray;
  for i := 0 to High(AItem.Tags) do arr.AddItem(JSONString(AItem.Tags[i]));
  obj.AddPair('tags', arr);

  arr := JSONArray;
  for i := 0 to High(AItem.Roles) do arr.AddItem(JSONString(AItem.Roles[i]));
  obj.AddPair('roles', arr);

  arr := JSONArray;
  for i := 0 to High(AItem.Presets) do arr.AddItem(JSONString(AItem.Presets[i]));
  obj.AddPair('presets', arr);

  obj.AddPair('available', JSONBool(AItem.Available));
  Result := obj;
end;

function TInstrumentCatalogue.SafeDescriptionsJSON: TJSONValue;
var
  i: Integer;
begin
  Result := JSONArray;
  for i := 0 to FItems.Count - 1 do
    Result.AddItem(SafeDescriptionJSON(FItems[i]));
end;

procedure TInstrumentCatalogue.SaveToFile(const AFileName: string);
var
  fn: string;
  root, arr, obj: TJSONValue;
  i, j: Integer;
  sl: TStringList;
  item: TCatalogueItem;
  tagsArr: TJSONValue;
begin
  fn := AFileName;
  if fn = '' then fn := DataFile(CATALOGUE_FILE_NAME);
  ForceDirectories(ExtractFilePath(fn));

  root := JSONObject;
  try
    root.AddPair('version', JSONNumber(CATALOGUE_FILE_VERSION));
    arr := JSONArray;
    for i := 0 to FItems.Count - 1 do
    begin
      item := FItems[i];
      obj := JSONObject;
      obj.AddPair('id', JSONString(item.Id));
      obj.AddPair('name', JSONString(item.Name));
      obj.AddPair('category', JSONString(item.Category));
      obj.AddPair('kind', JSONString(CatalogueItemKindId(item.Kind)));
      obj.AddPair('path', JSONString(item.Path));
      obj.AddPair('noteRangeLow', JSONNumber(item.NoteRangeLow));
      obj.AddPair('noteRangeHigh', JSONNumber(item.NoteRangeHigh));
      obj.AddPair('available', JSONBool(item.Available));
      obj.AddPair('lastScanUTC', JSONString(SimpleIso(item.LastScanUTC)));
      obj.AddPair('platform', JSONString(item.PlatformTag));

      tagsArr := JSONArray;
      for j := 0 to High(item.Tags) do tagsArr.AddItem(JSONString(item.Tags[j]));
      obj.AddPair('tags', tagsArr);

      tagsArr := JSONArray;
      for j := 0 to High(item.Roles) do tagsArr.AddItem(JSONString(item.Roles[j]));
      obj.AddPair('roles', tagsArr);

      tagsArr := JSONArray;
      for j := 0 to High(item.Presets) do tagsArr.AddItem(JSONString(item.Presets[j]));
      obj.AddPair('presets', tagsArr);

      arr.AddItem(obj);
    end;
    root.AddPair('items', arr);

    sl := TStringList.Create;
    try
      sl.Text := root.ToJSONString;
      sl.SaveToFile(fn, TEncoding.UTF8);
    finally
      sl.Free;
    end;
  finally
    root.Free;
  end;
end;

procedure TInstrumentCatalogue.LoadFromFile(const AFileName: string);
var
  fn, text: string;
  root, itemsArr, obj, sub: TJSONValue;
  i, j: Integer;
  item: TCatalogueItem;
  kind: TCatalogueItemKind;
  sl: TStringList;
begin
  fn := AFileName;
  if fn = '' then fn := DataFile(CATALOGUE_FILE_NAME);
  Clear;
  if not FileExists(fn) then Exit;

  sl := TStringList.Create;
  try
    sl.LoadFromFile(fn, TEncoding.UTF8);
    text := sl.Text;
  finally
    sl.Free;
  end;

  root := Parse(text);
  try
    itemsArr := root.ByName('items');
    if itemsArr = nil then Exit;
    for i := 0 to itemsArr.Count - 1 do
    begin
      obj := itemsArr.Items[i];
      item := TCatalogueItem.Create;
      item.Id := obj.ByName('id').AsString;
      item.Name := obj.ByName('name').AsString;
      item.Category := obj.ByName('category').AsString;
      if CatalogueItemKindFromId(obj.ByName('kind').AsString, kind) then
        item.Kind := kind;
      item.Path := obj.ByName('path').AsString;
      if obj.HasName('noteRangeLow') then item.NoteRangeLow := Trunc(obj.ByName('noteRangeLow').AsNumber);
      if obj.HasName('noteRangeHigh') then item.NoteRangeHigh := Trunc(obj.ByName('noteRangeHigh').AsNumber);
      item.Available := obj.HasName('available') and obj.ByName('available').AsBool;
      if obj.HasName('platform') then item.PlatformTag := obj.ByName('platform').AsString;

      sub := obj.ByName('tags');
      if sub <> nil then
      begin
        SetLength(item.FTags, sub.Count);
        for j := 0 to sub.Count - 1 do item.FTags[j] := sub.Items[j].AsString;
      end;
      sub := obj.ByName('roles');
      if sub <> nil then
      begin
        SetLength(item.FRoles, sub.Count);
        for j := 0 to sub.Count - 1 do item.FRoles[j] := sub.Items[j].AsString;
      end;
      sub := obj.ByName('presets');
      if sub <> nil then
      begin
        SetLength(item.FPresets, sub.Count);
        for j := 0 to sub.Count - 1 do item.FPresets[j] := sub.Items[j].AsString;
      end;

      FItems.Add(item);
    end;
  finally
    root.Free;
  end;
end;

end.
