unit UDAW.Project.DialogPaths;
{$I udaw.inc}

{ Project System: the last file or folder each file dialog was used with.

  Every open / save / folder dialog is known by a stable key (its component name, or the folder
  picker's caption); the project remembers the path last chosen through it and hands it back
  the next time that dialog opens - also after the project is closed and loaded again, because
  the list is saved in the project file. Dialogs the user has not touched yet fall back to the
  application-wide last folder. }

interface

uses
  SysUtils, Classes, Generics.Collections;

type
  TDialogPaths = class
  private
    FPaths: TDictionary<string, string>;
  public
    constructor Create;
    destructor Destroy; override;
    function Clone: TDialogPaths;
    { the remembered path for a dialog, '' when it has none }
    function Get(const AKey: string): string;
    procedure Put(const AKey, APath: string);
    function Count: Integer;
    property Paths: TDictionary<string, string> read FPaths;
  end;

function DialogPathsToString(APaths: TDialogPaths): string;
{ always returns a non-nil object (an empty or unreadable text gives an empty list) }
function DialogPathsFromString(const AText: string): TDialogPaths;

implementation

constructor TDialogPaths.Create;
begin
  inherited Create;
  FPaths := TDictionary<string, string>.Create;
end;

destructor TDialogPaths.Destroy;
begin
  FPaths.Free;
  inherited Destroy;
end;

function TDialogPaths.Clone: TDialogPaths;
var
  p: TPair<string, string>;
begin
  Result := TDialogPaths.Create;
  for p in FPaths do Result.FPaths.AddOrSetValue(p.Key, p.Value);
end;

function TDialogPaths.Get(const AKey: string): string;
begin
  if not FPaths.TryGetValue(LowerCase(AKey), Result) then Result := '';
end;

procedure TDialogPaths.Put(const AKey, APath: string);
begin
  if (Trim(AKey) = '') or (Trim(APath) = '') then Exit;
  FPaths.AddOrSetValue(LowerCase(AKey), APath);
end;

function TDialogPaths.Count: Integer;
begin
  Result := FPaths.Count;
end;

function DialogPathsToString(APaths: TDialogPaths): string;
var
  keys: TArray<string>;
  sb: TStringBuilder;
  k: string;
begin
  sb := TStringBuilder.Create;
  try
    sb.Append('UDAWDIALOGS 1').AppendLine;
    keys := APaths.FPaths.Keys.ToArray;
    TArray.Sort<string>(keys);
    for k in keys do
      sb.Append(k).Append('=').Append(APaths.FPaths[k]).AppendLine;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function DialogPathsFromString(const AText: string): TDialogPaths;
var
  lines: TStringList;
  i, p: Integer;
  line: string;
begin
  Result := TDialogPaths.Create;
  lines := TStringList.Create;
  try
    lines.Text := AText;
    for i := 0 to lines.Count - 1 do
    begin
      line := lines[i];
      p := Pos('=', line);
      if p <= 1 then Continue;   // the header line and anything unreadable
      Result.Put(Copy(line, 1, p - 1), Copy(line, p + 1, MaxInt));
    end;
  finally
    lines.Free;
  end;
end;

end.
