unit UDAW.Drum.KitModel;
{$I udaw.inc}

{ The drum machine's kit as project data: which sample sits on which pad, the pad's
  name, level, pan, mute, solo, choke group and play mode, and a small waveform
  overview of the sample. It is saved in the project file (the DRUMKIT section), so
  a project reopens with every instrument panel and its sound graph in place - the
  overview is stored too, so the graph still shows if the sample file has moved.

  This unit holds data only (no audio, no UI): the main form copies the live drum
  machine into it as pads change, and loads the kit back from it when a project
  opens. }

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Generics.Collections,
  UDAW.Errors;

const
  DRUMKIT_MAGIC = 'UDAWDRUMKIT';
  DRUMKIT_VERSION = 1;
  DRUMKIT_SUBSYS = 'DrumKit';
  DRUMKIT_PEAK_COLUMNS = 256;
  DRUMKIT_PEAK_SCALE = 1000;     { peaks are stored as integers, -1000..1000 }

type
  TDrumKitPadData = record
    Note: Integer;
    Path: string;
    Name: string;
    Level: Single;
    Pan: Single;
    Muted, Soloed: Boolean;
    Choke: Integer;
    Mode: Integer;                { 0 one-shot, 1 gate }
    Rate, Frames, Channels: Integer;
    { min / max pairs, DRUMKIT_PEAK_COLUMNS columns, scaled by DRUMKIT_PEAK_SCALE }
    Peaks: TArray<SmallInt>;
  end;

  TDrumKitModel = class
  private
    FPads: TList<TDrumKitPadData>;
    FDefined: Boolean;
    function GetCount: Integer;
    function GetPad(AIndex: Integer): TDrumKitPadData;
  public
    constructor Create;
    destructor Destroy; override;
    function Clone: TDrumKitModel;
    procedure Clear;
    function IndexOfNote(ANote: Integer): Integer;
    { adds the pad, or replaces the one on the same note; keeps the list sorted by note }
    procedure Put(const APad: TDrumKitPadData);
    procedure Remove(ANote: Integer);
    property Count: Integer read GetCount;
    property Pads[AIndex: Integer]: TDrumKitPadData read GetPad; default;
    { True once the kit has been saved with, or loaded from, a project - a project that
      has never held a kit (an older file) leaves the player's current kit alone }
    property Defined: Boolean read FDefined write FDefined;
  end;

function DrumKitToString(AKit: TDrumKitModel): string;
function DrumKitFromString(const AText: string): TDrumKitModel;   // caller owns it

implementation

{ TDrumKitModel }

constructor TDrumKitModel.Create;
begin
  inherited Create;
  FPads := TList<TDrumKitPadData>.Create;
end;

destructor TDrumKitModel.Destroy;
begin
  FPads.Free;
  inherited Destroy;
end;

function TDrumKitModel.GetCount: Integer;
begin
  Result := FPads.Count;
end;

function TDrumKitModel.GetPad(AIndex: Integer): TDrumKitPadData;
begin
  Result := FPads[AIndex];
end;

function TDrumKitModel.Clone: TDrumKitModel;
var
  i: Integer;
  d: TDrumKitPadData;
begin
  Result := TDrumKitModel.Create;
  Result.FDefined := FDefined;
  for i := 0 to FPads.Count - 1 do
  begin
    d := FPads[i];
    d.Peaks := Copy(d.Peaks);
    Result.FPads.Add(d);
  end;
end;

procedure TDrumKitModel.Clear;
begin
  FPads.Clear;
end;

function TDrumKitModel.IndexOfNote(ANote: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to FPads.Count - 1 do
    if FPads[i].Note = ANote then Exit(i);
  Result := -1;
end;

procedure TDrumKitModel.Put(const APad: TDrumKitPadData);
var
  i: Integer;
begin
  FDefined := True;
  i := IndexOfNote(APad.Note);
  if i >= 0 then
  begin
    FPads[i] := APad;
    Exit;
  end;
  i := 0;
  while (i < FPads.Count) and (FPads[i].Note < APad.Note) do Inc(i);
  FPads.Insert(i, APad);
end;

procedure TDrumKitModel.Remove(ANote: Integer);
var
  i: Integer;
begin
  FDefined := True;
  i := IndexOfNote(ANote);
  if i >= 0 then FPads.Delete(i);
end;

{ ---- text form ----
    UDAWDRUMKIT 1
    PAD <note> "<path>" "<name>" <level> <pan> <mute> <solo> <choke> <mode> <rate> <frames> <channels>
    PEAKS <count> <v> <v> ...      (belongs to the PAD above it) }

function Quote(const S: string): string;
begin
  Result := '"' + StringReplace(S, '"', '''', [rfReplaceAll]) + '"';
end;

function Tok(var S: string): string;
var
  sp: Integer;
begin
  S := TrimLeft(S);
  sp := Pos(' ', S);
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

function TakeQuoted(var S: string): string;
var
  closeAt, i: Integer;
begin
  S := TrimLeft(S);
  if (S = '') or (S[1] <> '"') then
    RaiseUDAW(errConfig, DRUMKIT_SUBSYS, 'drum kit parse: expected a quoted value');
  closeAt := 0;
  for i := 2 to Length(S) do
    if S[i] = '"' then
    begin
      closeAt := i;
      Break;
    end;
  if closeAt = 0 then
    RaiseUDAW(errConfig, DRUMKIT_SUBSYS, 'drum kit parse: unterminated quoted value');
  Result := Copy(S, 2, closeAt - 2);
  S := TrimLeft(Copy(S, closeAt + 1, MaxInt));
end;

function DrumKitToString(AKit: TDrumKitModel): string;
var
  sb: TStringBuilder;
  i, k: Integer;
  d: TDrumKitPadData;
  fs: TFormatSettings;
begin
  fs := TFormatSettings.Invariant;
  sb := TStringBuilder.Create;
  try
    sb.Append(DRUMKIT_MAGIC).Append(' ').Append(DRUMKIT_VERSION).AppendLine;
    for i := 0 to AKit.Count - 1 do
    begin
      d := AKit[i];
      sb.Append('PAD ').Append(d.Note).Append(' ').Append(Quote(d.Path)).Append(' ')
        .Append(Quote(d.Name)).Append(' ')
        .Append(FormatFloat('0.###', d.Level, fs)).Append(' ')
        .Append(FormatFloat('0.###', d.Pan, fs)).Append(' ')
        .Append(Ord(d.Muted)).Append(' ').Append(Ord(d.Soloed)).Append(' ')
        .Append(d.Choke).Append(' ').Append(d.Mode).Append(' ')
        .Append(d.Rate).Append(' ').Append(d.Frames).Append(' ').Append(d.Channels).AppendLine;
      if Length(d.Peaks) > 0 then
      begin
        sb.Append('PEAKS ').Append(Length(d.Peaks));
        for k := 0 to High(d.Peaks) do sb.Append(' ').Append(Integer(d.Peaks[k]));
        sb.AppendLine;
      end;
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function DrumKitFromString(const AText: string): TDrumKitModel;
var
  lines: TStringList;
  i, ver, k, n: Integer;
  line, key: string;
  d: TDrumKitPadData;
  havePad: Boolean;
  fs: TFormatSettings;
  v: Double;

  procedure Flush;
  begin
    if havePad then Result.Put(d);
    havePad := False;
  end;

begin
  fs := TFormatSettings.Invariant;
  Result := TDrumKitModel.Create;
  lines := TStringList.Create;
  try
    try
      lines.Text := AText;
      i := 0;
      while (i < lines.Count) and (Trim(lines[i]) = '') do Inc(i);
      if i >= lines.Count then
      begin
        Result.Defined := True;           // an empty block: a kit that was deliberately empty
        Exit;
      end;
      line := Trim(lines[i]);
      Inc(i);
      if not SameText(Tok(line), DRUMKIT_MAGIC) then
        RaiseUDAW(errConfig, DRUMKIT_SUBSYS, 'not a drum kit document');
      ver := StrToIntDef(Tok(line), 0);
      if (ver <= 0) or (ver > DRUMKIT_VERSION) then
        RaiseUDAWFmt(errConfig, DRUMKIT_SUBSYS, 'unsupported drum kit version %d', [ver]);
      Result.Defined := True;
      havePad := False;
      while i < lines.Count do
      begin
        line := Trim(lines[i]);
        Inc(i);
        if line = '' then Continue;
        key := Tok(line);
        if SameText(key, 'PAD') then
        begin
          Flush;
          d := Default(TDrumKitPadData);
          d.Note := EnsureRange(StrToIntDef(Tok(line), 0), 0, 127);
          d.Path := TakeQuoted(line);
          d.Name := TakeQuoted(line);
          if TryStrToFloat(Tok(line), v, fs) then d.Level := v else d.Level := 1;
          if TryStrToFloat(Tok(line), v, fs) then d.Pan := v;
          d.Muted := Tok(line) = '1';
          d.Soloed := Tok(line) = '1';
          d.Choke := EnsureRange(StrToIntDef(Tok(line), 0), 0, 8);
          d.Mode := EnsureRange(StrToIntDef(Tok(line), 0), 0, 1);
          d.Rate := StrToIntDef(Tok(line), 0);
          d.Frames := StrToIntDef(Tok(line), 0);
          d.Channels := StrToIntDef(Tok(line), 0);
          havePad := True;
        end
        else if SameText(key, 'PEAKS') and havePad then
        begin
          n := EnsureRange(StrToIntDef(Tok(line), 0), 0, DRUMKIT_PEAK_COLUMNS * 2);
          SetLength(d.Peaks, n);
          for k := 0 to n - 1 do
            d.Peaks[k] := EnsureRange(StrToIntDef(Tok(line), 0), -DRUMKIT_PEAK_SCALE, DRUMKIT_PEAK_SCALE);
        end
        else
          RaiseUDAWFmt(errConfig, DRUMKIT_SUBSYS, 'drum kit parse: unexpected line "%s"', [line]);
      end;
      Flush;
    except
      Result.Free;
      raise;
    end;
  finally
    lines.Free;
  end;
end;

end.
