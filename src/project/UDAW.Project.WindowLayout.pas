unit UDAW.Project.WindowLayout;
{$I udaw.inc}

{ Project System: per-project remembered window layout (docs plan: "the
  system needs to remember all windows that were opened, their positions on
  closure and restored again on startup for each individual project").

  TWindowLayout is a small, flat list of TWindowLayoutEntry - one per
  secondary/child window the user had open (Log Viewer, Browser Window, a
  VST2 plugin editor, ...), keyed by a stable string identifying which
  window it is. Singleton windows use a fixed key ("LogViewer",
  "BrowserWindow"); per-object windows (a VST2 editor for a specific mixer
  insert) use a composite key ("VST2Editor:<stripId>:<insertIndex>") so each
  instance's geometry is remembered independently and can be matched back to
  its owning insert on reopen (or silently dropped if that insert no longer
  exists).

  Follows the project's existing per-subsystem-root style (TSongSpec,
  TMidiProject, ...): a Clone method for the project Clone/recovery path,
  and TObjectList-owned children. Entries only record the LAST known
  geometry of a window - an entry existing at all means "this window was
  open at some point and should reopen at this position"; MainForm removes
  an entry when the corresponding window is closed with no intent to
  reopen it (there currently is none - every remembered window is meant to
  reopen), and updates it in place whenever the window is opened, closed, or
  save happens while it is open. }

interface

uses
  SysUtils, Classes, Generics.Collections,
  UDAW.Errors;

const
  WINDOWLAYOUT_SUBSYS  = 'Project.WindowLayout';
  WINDOWLAYOUT_MAGIC   = 'UDAWWINDOWS';
  WINDOWLAYOUT_VERSION = 1;

type
  { Mirrors TWindowState (wsNormal/wsMinimized/wsMaximized) without pulling
    in the VCL/LCL Forms unit - this model is UI-toolkit free like every
    other project sub-model. }
  TSavedWindowState = (swsNormal, swsMinimized, swsMaximized);

  TWindowLayoutEntry = class
  private
    FKey: string;
    FLeft: Integer;
    FTop: Integer;
    FWidth: Integer;
    FHeight: Integer;
    FState: TSavedWindowState;
  public
    constructor Create(const AKey: string = ''; ALeft: Integer = 0; ATop: Integer = 0;
      AWidth: Integer = 0; AHeight: Integer = 0; AState: TSavedWindowState = swsNormal);
    function Clone: TWindowLayoutEntry;
    property Key: string read FKey write FKey;
    property Left: Integer read FLeft write FLeft;
    property Top: Integer read FTop write FTop;
    property Width: Integer read FWidth write FWidth;
    property Height: Integer read FHeight write FHeight;
    property State: TSavedWindowState read FState write FState;
  end;

  TWindowLayout = class
  private
    FEntries: TObjectList<TWindowLayoutEntry>;
  public
    constructor Create;
    destructor Destroy; override;
    function Clone: TWindowLayout;

    { Finds the entry for AKey, or nil if that window has never been
      remembered. }
    function Find(const AKey: string): TWindowLayoutEntry;
    { Adds or updates (by Key) the remembered geometry for a window. }
    procedure Put(const AKey: string; ALeft, ATop, AWidth, AHeight: Integer;
      AState: TSavedWindowState = swsNormal);
    { Forgets a remembered window entirely (it will not reopen next time). }
    procedure Remove(const AKey: string);
    { Every remembered key that starts with APrefix, e.g. all VST2Editor
      instances - so the caller can drop entries whose owning insert no
      longer exists in the project without needing every possible key. }
    procedure RemoveByPrefix(const APrefix: string);

    property Entries: TObjectList<TWindowLayoutEntry> read FEntries;
  end;

function WindowLayoutToString(ALayout: TWindowLayout): string;
{ Parses a payload produced by WindowLayoutToString. Always returns a
  non-nil, possibly-empty layout (an empty AText yields no entries) - the
  caller owns the result and must Free it. }
function WindowLayoutFromString(const AText: string): TWindowLayout;

implementation

function QuoteStr(const S: string): string;
begin
  Result := '"' + StringReplace(S, '"', '''', [rfReplaceAll]) + '"';
end;

function TakeQuoted(var S: string): string;
var
  i, closeAt: Integer;
begin
  S := TrimLeft(S);
  if (S = '') or (S[1] <> '"') then
    RaiseUDAW(errConfig, WINDOWLAYOUT_SUBSYS, 'window layout parse: expected a quoted value');
  closeAt := 0;
  for i := 2 to Length(S) do
    if S[i] = '"' then begin closeAt := i; Break; end;
  if closeAt = 0 then
    RaiseUDAW(errConfig, WINDOWLAYOUT_SUBSYS, 'window layout parse: unterminated quoted value');
  Result := Copy(S, 2, closeAt - 2);
  S := TrimLeft(Copy(S, closeAt + 1, MaxInt));
end;

function TakeToken(var S: string): string;
var
  sp: Integer;
begin
  S := TrimLeft(S);
  sp := Pos(' ', S);
  if sp = 0 then sp := Pos(#9, S);
  if sp = 0 then
  begin
    Result := S;
    S := '';
  end
  else
  begin
    Result := Copy(S, 1, sp - 1);
    S := TrimLeft(Copy(S, sp + 1, MaxInt));
  end;
end;

function I32(const S: string): Integer;
begin
  if not TryStrToInt(Trim(S), Result) then
    RaiseUDAWFmt(errConfig, WINDOWLAYOUT_SUBSYS, 'window layout parse: "%s" is not an integer', [S]);
end;

constructor TWindowLayoutEntry.Create(const AKey: string; ALeft, ATop, AWidth, AHeight: Integer;
  AState: TSavedWindowState);
begin
  inherited Create;
  FKey := AKey;
  FLeft := ALeft;
  FTop := ATop;
  FWidth := AWidth;
  FHeight := AHeight;
  FState := AState;
end;

function TWindowLayoutEntry.Clone: TWindowLayoutEntry;
begin
  Result := TWindowLayoutEntry.Create(FKey, FLeft, FTop, FWidth, FHeight, FState);
end;

constructor TWindowLayout.Create;
begin
  inherited Create;
  FEntries := TObjectList<TWindowLayoutEntry>.Create(True);
end;

destructor TWindowLayout.Destroy;
begin
  FEntries.Free;
  inherited Destroy;
end;

function TWindowLayout.Clone: TWindowLayout;
var
  i: Integer;
begin
  Result := TWindowLayout.Create;
  for i := 0 to FEntries.Count - 1 do
    Result.FEntries.Add(FEntries[i].Clone);
end;

function TWindowLayout.Find(const AKey: string): TWindowLayoutEntry;
var
  i: Integer;
begin
  for i := 0 to FEntries.Count - 1 do
    if SameText(FEntries[i].Key, AKey) then
      Exit(FEntries[i]);
  Result := nil;
end;

procedure TWindowLayout.Put(const AKey: string; ALeft, ATop, AWidth, AHeight: Integer;
  AState: TSavedWindowState);
var
  e: TWindowLayoutEntry;
begin
  e := Find(AKey);
  if e = nil then
  begin
    e := TWindowLayoutEntry.Create(AKey);
    FEntries.Add(e);
  end;
  e.Left := ALeft;
  e.Top := ATop;
  e.Width := AWidth;
  e.Height := AHeight;
  e.State := AState;
end;

procedure TWindowLayout.Remove(const AKey: string);
var
  i: Integer;
begin
  for i := FEntries.Count - 1 downto 0 do
    if SameText(FEntries[i].Key, AKey) then
      FEntries.Delete(i);
end;

procedure TWindowLayout.RemoveByPrefix(const APrefix: string);
var
  i: Integer;
begin
  for i := FEntries.Count - 1 downto 0 do
    if FEntries[i].Key.StartsWith(APrefix, True) then
      FEntries.Delete(i);
end;

function WindowLayoutToString(ALayout: TWindowLayout): string;
var
  sb: TStringBuilder;
  i: Integer;
  e: TWindowLayoutEntry;
begin
  sb := TStringBuilder.Create;
  try
    sb.Append(WINDOWLAYOUT_MAGIC).Append(' ').Append(WINDOWLAYOUT_VERSION).AppendLine;
    if ALayout <> nil then
      for i := 0 to ALayout.Entries.Count - 1 do
      begin
        e := ALayout.Entries[i];
        sb.Append('WINDOW ').Append(QuoteStr(e.Key))
          .Append(' ').Append(e.Left).Append(' ').Append(e.Top)
          .Append(' ').Append(e.Width).Append(' ').Append(e.Height)
          .Append(' ').Append(Ord(e.State)).AppendLine;
      end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function WindowLayoutFromString(const AText: string): TWindowLayout;
var
  lines: TStringList;
  li, ver, stateOrd: Integer;
  raw, line, tok: string;
  layout: TWindowLayout;
  haveHeader: Boolean;
  key: string;
  l, t, w, h: Integer;
begin
  layout := TWindowLayout.Create;
  lines := TStringList.Create;
  try
    lines.Text := AText;
    haveHeader := False;

    for li := 0 to lines.Count - 1 do
    begin
      raw := Trim(lines[li]);
      if (raw = '') or (raw[1] = '#') then Continue;
      line := raw;
      tok := TakeToken(line);

      if not haveHeader then
      begin
        if not SameText(tok, WINDOWLAYOUT_MAGIC) then
          RaiseUDAW(errConfig, WINDOWLAYOUT_SUBSYS, 'not a UDAWWINDOWS section');
        if not TryStrToInt(Trim(line), ver) then
          RaiseUDAW(errConfig, WINDOWLAYOUT_SUBSYS, 'window layout header: missing version number');
        if (ver <= 0) or (ver > WINDOWLAYOUT_VERSION) then
          RaiseUDAWFmt(errConfig, WINDOWLAYOUT_SUBSYS,
            'unsupported UDAWWINDOWS version %d (reader supports up to %d)', [ver, WINDOWLAYOUT_VERSION]);
        haveHeader := True;
        Continue;
      end;

      if SameText(tok, 'WINDOW') then
      begin
        key := TakeQuoted(line);
        l := I32(TakeToken(line));
        t := I32(TakeToken(line));
        w := I32(TakeToken(line));
        h := I32(TakeToken(line));
        stateOrd := I32(line);
        if (stateOrd < Ord(Low(TSavedWindowState))) or (stateOrd > Ord(High(TSavedWindowState))) then
          stateOrd := Ord(swsNormal);
        layout.Put(key, l, t, w, h, TSavedWindowState(stateOrd));
      end
      else
        RaiseUDAWFmt(errConfig, WINDOWLAYOUT_SUBSYS, 'window layout parse: unexpected line "%s"', [raw]);
    end;

    Result := layout;
    layout := nil;
  finally
    layout.Free;
    lines.Free;
  end;
end;

end.
