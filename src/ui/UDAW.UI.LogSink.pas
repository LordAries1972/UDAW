unit UDAW.UI.LogSink;

{ A non-visual stand-in for the read-only text panels that used to show log and
  readout text on screen. Code keeps writing to Lines (Add, Insert, Text := ...)
  exactly as before, but nothing is displayed: every change is appended to a text
  file in the log folder (ui-<name>.log), so the output survives for support
  and debugging. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes;

type
  TLogSink = class(TComponent)
  private
    FLines: TStringList;
    FLast: string;
    FPath: string;
    FLastFull: Cardinal;
    procedure LinesChanged(Sender: TObject);
    function GetText: string;
    procedure SetText(const AValue: string);
    function FileName: string;
    procedure Emit(const AText: string);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Clear;
    property Lines: TStringList read FLines;
    property Text: string read GetText write SetText;
    { the file this sink writes to }
    property Path: string read FPath;
  end;

implementation

uses
  UDAW.Paths;

constructor TLogSink.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLines := TStringList.Create;
  FLines.OnChange := LinesChanged;
end;

destructor TLogSink.Destroy;
begin
  FLines.OnChange := nil;
  FLines.Free;
  inherited Destroy;
end;

function TLogSink.FileName: string;
var
  n: string;
begin
  if FPath = '' then
  begin
    n := Name;
    if (Length(n) > 3) and SameText(Copy(n, 1, 3), 'mem') then Delete(n, 1, 3);
    if n = '' then n := 'panel';
    FPath := LogFile('ui-' + LowerCase(n) + '.log');
  end;
  Result := FPath;
end;

procedure TLogSink.Emit(const AText: string);
var
  f: TextFile;
  fn: string;
begin
  if AText = '' then Exit;
  try
    fn := FileName;
    ForceDirectories(ExtractFilePath(fn));
    AssignFile(f, fn);
    if FileExists(fn) then Append(f) else Rewrite(f);
    try
      Write(f, AText);
    finally
      CloseFile(f);
    end;
  except
    { a log that cannot be written must never disturb the caller }
  end;
end;

{ only what changed is written: lines added at the end or the top are appended
  with a time stamp; any other change writes the whole text under a marker }
procedure TLogSink.LinesChanged(Sender: TObject);
var
  cur, delta, stamp: string;
  sl: TStringList;
  i: Integer;
begin
  cur := FLines.Text;
  if cur = FLast then Exit;
  stamp := FormatDateTime('hh:nn:ss.zzz', Now);
  if (FLast <> '') and (Length(cur) > Length(FLast)) and (Copy(cur, 1, Length(FLast)) = FLast) then
    delta := Copy(cur, Length(FLast) + 1, MaxInt)
  else if (FLast <> '') and (Length(cur) > Length(FLast)) and
          (Copy(cur, Length(cur) - Length(FLast) + 1, Length(FLast)) = FLast) then
    delta := Copy(cur, 1, Length(cur) - Length(FLast))
  else
    delta := '';
  FLast := cur;
  if delta <> '' then
  begin
    sl := TStringList.Create;
    try
      sl.Text := delta;
      delta := '';
      for i := 0 to sl.Count - 1 do delta := delta + stamp + ' ' + sl[i] + sLineBreak;
    finally
      sl.Free;
    end;
    Emit(delta);
  end
  else if cur <> '' then
  begin
    { a readout rewritten many times a second (engine status, meters) is
      recorded at most every 30 seconds so the file stays readable }
    if (FLastFull = 0) or (GetTickCount - FLastFull >= 30000) then
    begin
      FLastFull := GetTickCount;
      if FLastFull = 0 then FLastFull := 1;
      Emit('--- ' + stamp + ' ---' + sLineBreak + cur);
    end;
  end;
end;

function TLogSink.GetText: string;
begin
  Result := FLines.Text;
end;

procedure TLogSink.SetText(const AValue: string);
begin
  FLines.Text := AValue;
end;

procedure TLogSink.Clear;
begin
  FLines.Clear;
  FLast := '';
end;

initialization
  RegisterClass(TLogSink);

end.
