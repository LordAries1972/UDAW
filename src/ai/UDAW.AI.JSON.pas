unit UDAW.AI.JSON;
{$I udaw.inc}

{ Phase 20 - a minimal, fully self-written JSON value / parser / writer.
  No platform JSON library is used, matching how this project writes every
  other file format (MP3, MP4, tracker formats, ...) from scratch. Used by
  the AI-provider request/response bodies (Phases 21-23) and the MCP
  JSON-RPC transport (UDAW.AI.MCP).

  TJSONValue owns its children: freeing an array or object value recursively
  frees every element / member value. Parse() returns a value the CALLER
  owns and must Free (including on the error path - callers that catch a
  parse error simply never receive a value to free). }

interface

uses
  SysUtils, Classes, UDAW.Errors;

type
  TJSONKind = (jkNull, jkBool, jkNumber, jkString, jkArray, jkObject);

  TJSONValue = class
  private
    FKind: TJSONKind;
    FBool: Boolean;
    FNumber: Double;
    FString: string;
    FItems: TArray<TJSONValue>;
    FNames: TArray<string>;
    FValues: TArray<TJSONValue>;
    function GetCount: Integer;
    function GetItem(AIndex: Integer): TJSONValue;
    function GetName(AIndex: Integer): string;
    function GetValue(AIndex: Integer): TJSONValue;
  public
    constructor Create(AKind: TJSONKind);
    destructor Destroy; override;

    property Kind: TJSONKind read FKind;
    property AsBool: Boolean read FBool write FBool;
    property AsNumber: Double read FNumber write FNumber;
    property AsString: string read FString write FString;

    { array access }
    property Count: Integer read GetCount;
    property Items[AIndex: Integer]: TJSONValue read GetItem;
    procedure AddItem(AValue: TJSONValue);

    { object access }
    property Names[AIndex: Integer]: string read GetName;
    property Values[AIndex: Integer]: TJSONValue read GetValue;
    procedure AddPair(const AName: string; AValue: TJSONValue);
    function ByName(const AName: string): TJSONValue;
    function HasName(const AName: string): Boolean;

    function ToJSONString: string;
  end;

function JSONNull: TJSONValue;
function JSONBool(AValue: Boolean): TJSONValue;
function JSONNumber(AValue: Double): TJSONValue;
function JSONString(const AValue: string): TJSONValue;
function JSONArray: TJSONValue;
function JSONObject: TJSONValue;

{ Parses AText into a TJSONValue tree. The caller owns the result and must
  Free it. Raises EUDAWError(errParse) on malformed input. }
function Parse(const AText: string): TJSONValue;

function JSONStringify(AValue: TJSONValue): string;

implementation

const
  SUBSYS = 'AI.JSON';

{ ---------------- construction ---------------- }

constructor TJSONValue.Create(AKind: TJSONKind);
begin
  inherited Create;
  FKind := AKind;
end;

destructor TJSONValue.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FItems) do
    FItems[i].Free;
  for i := 0 to High(FValues) do
    FValues[i].Free;
  inherited Destroy;
end;

function TJSONValue.GetCount: Integer;
begin
  case FKind of
    jkArray:  Result := Length(FItems);
    jkObject: Result := Length(FNames);
  else
    Result := 0;
  end;
end;

function TJSONValue.GetItem(AIndex: Integer): TJSONValue;
begin
  Result := FItems[AIndex];
end;

function TJSONValue.GetName(AIndex: Integer): string;
begin
  Result := FNames[AIndex];
end;

function TJSONValue.GetValue(AIndex: Integer): TJSONValue;
begin
  Result := FValues[AIndex];
end;

procedure TJSONValue.AddItem(AValue: TJSONValue);
begin
  SetLength(FItems, Length(FItems) + 1);
  FItems[High(FItems)] := AValue;
end;

procedure TJSONValue.AddPair(const AName: string; AValue: TJSONValue);
begin
  SetLength(FNames, Length(FNames) + 1);
  FNames[High(FNames)] := AName;
  SetLength(FValues, Length(FValues) + 1);
  FValues[High(FValues)] := AValue;
end;

function TJSONValue.ByName(const AName: string): TJSONValue;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to High(FNames) do
    if FNames[i] = AName then
      Exit(FValues[i]);
end;

function TJSONValue.HasName(const AName: string): Boolean;
begin
  Result := ByName(AName) <> nil;
end;

{ ---------------- factories ---------------- }

function JSONNull: TJSONValue;
begin
  Result := TJSONValue.Create(jkNull);
end;

function JSONBool(AValue: Boolean): TJSONValue;
begin
  Result := TJSONValue.Create(jkBool);
  Result.AsBool := AValue;
end;

function JSONNumber(AValue: Double): TJSONValue;
begin
  Result := TJSONValue.Create(jkNumber);
  Result.AsNumber := AValue;
end;

function JSONString(const AValue: string): TJSONValue;
begin
  Result := TJSONValue.Create(jkString);
  Result.AsString := AValue;
end;

function JSONArray: TJSONValue;
begin
  Result := TJSONValue.Create(jkArray);
end;

function JSONObject: TJSONValue;
begin
  Result := TJSONValue.Create(jkObject);
end;

{ ---------------- parser ---------------- }

type
  TJSONParser = record
    Text: string;
    Pos: Integer;   // 1-based index of the next unread char
    Len: Integer;
  end;

procedure PErrorFmt(const AParser: TJSONParser; const AReason: string);
begin
  RaiseUDAWFmt(errParse, SUBSYS, 'JSON parse error at position %d: %s',
    [AParser.Pos, AReason]);
end;

function PPeek(const AParser: TJSONParser): Char;
begin
  if AParser.Pos <= AParser.Len then
    Result := AParser.Text[AParser.Pos]
  else
    Result := #0;
end;

procedure PAdvance(var AParser: TJSONParser);
begin
  Inc(AParser.Pos);
end;

procedure PSkipWhitespace(var AParser: TJSONParser);
begin
  while (AParser.Pos <= AParser.Len) and
        CharInSet(AParser.Text[AParser.Pos], [' ', #9, #10, #13]) do
    Inc(AParser.Pos);
end;

procedure PExpect(var AParser: TJSONParser; AChar: Char);
begin
  if PPeek(AParser) <> AChar then
    PErrorFmt(AParser, Format('expected "%s"', [AChar]));
  PAdvance(AParser);
end;

function PParseValue(var AParser: TJSONParser): TJSONValue; forward;

function PParseHex4(var AParser: TJSONParser): Integer;
var
  i: Integer;
  c: Char;
  v: Integer;
begin
  Result := 0;
  for i := 1 to 4 do
  begin
    c := PPeek(AParser);
    case c of
      '0'..'9': v := Ord(c) - Ord('0');
      'a'..'f': v := Ord(c) - Ord('a') + 10;
      'A'..'F': v := Ord(c) - Ord('A') + 10;
    else
      PErrorFmt(AParser, 'invalid \u escape');
      v := 0;
    end;
    Result := (Result shl 4) or v;
    PAdvance(AParser);
  end;
end;

function PParseStringRaw(var AParser: TJSONParser): string;
var
  sb: TStringBuilder;
  c: Char;
  code: Integer;
begin
  PExpect(AParser, '"');
  sb := TStringBuilder.Create;
  try
    while True do
    begin
      if AParser.Pos > AParser.Len then
        PErrorFmt(AParser, 'unterminated string');
      c := AParser.Text[AParser.Pos];
      if c = '"' then
      begin
        PAdvance(AParser);
        Break;
      end
      else if c = '\' then
      begin
        PAdvance(AParser);
        c := PPeek(AParser);
        case c of
          '"': begin sb.Append('"'); PAdvance(AParser); end;
          '\': begin sb.Append('\'); PAdvance(AParser); end;
          '/': begin sb.Append('/'); PAdvance(AParser); end;
          'b': begin sb.Append(#8); PAdvance(AParser); end;
          'f': begin sb.Append(#12); PAdvance(AParser); end;
          'n': begin sb.Append(#10); PAdvance(AParser); end;
          'r': begin sb.Append(#13); PAdvance(AParser); end;
          't': begin sb.Append(#9); PAdvance(AParser); end;
          'u': begin
            PAdvance(AParser);
            code := PParseHex4(AParser);
            sb.Append(Char(code));
          end;
        else
          PErrorFmt(AParser, 'invalid escape sequence');
        end;
      end
      else
      begin
        sb.Append(c);
        PAdvance(AParser);
      end;
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function PParseNumber(var AParser: TJSONParser): Double;
var
  startPos: Integer;
  s: string;
  c: Char;
begin
  startPos := AParser.Pos;
  if PPeek(AParser) = '-' then
    PAdvance(AParser);
  if not CharInSet(PPeek(AParser), ['0'..'9']) then
    PErrorFmt(AParser, 'invalid number');
  while CharInSet(PPeek(AParser), ['0'..'9']) do
    PAdvance(AParser);
  if PPeek(AParser) = '.' then
  begin
    PAdvance(AParser);
    if not CharInSet(PPeek(AParser), ['0'..'9']) then
      PErrorFmt(AParser, 'invalid number (fraction)');
    while CharInSet(PPeek(AParser), ['0'..'9']) do
      PAdvance(AParser);
  end;
  c := PPeek(AParser);
  if (c = 'e') or (c = 'E') then
  begin
    PAdvance(AParser);
    c := PPeek(AParser);
    if (c = '+') or (c = '-') then
      PAdvance(AParser);
    if not CharInSet(PPeek(AParser), ['0'..'9']) then
      PErrorFmt(AParser, 'invalid number (exponent)');
    while CharInSet(PPeek(AParser), ['0'..'9']) do
      PAdvance(AParser);
  end;
  s := Copy(AParser.Text, startPos, AParser.Pos - startPos);
  Result := StrToFloat(s, TFormatSettings.Invariant);
end;

function PParseLiteral(var AParser: TJSONParser; const ALiteral: string): Boolean;
begin
  Result := Copy(AParser.Text, AParser.Pos, Length(ALiteral)) = ALiteral;
  if Result then
    Inc(AParser.Pos, Length(ALiteral));
end;

function PParseArray(var AParser: TJSONParser): TJSONValue;
var
  v: TJSONValue;
begin
  Result := JSONArray;
  try
    PExpect(AParser, '[');
    PSkipWhitespace(AParser);
    if PPeek(AParser) = ']' then
    begin
      PAdvance(AParser);
      Exit;
    end;
    while True do
    begin
      PSkipWhitespace(AParser);
      v := PParseValue(AParser);
      Result.AddItem(v);
      PSkipWhitespace(AParser);
      if PPeek(AParser) = ',' then
      begin
        PAdvance(AParser);
        Continue;
      end;
      PExpect(AParser, ']');
      Break;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function PParseObject(var AParser: TJSONParser): TJSONValue;
var
  name: string;
  v: TJSONValue;
begin
  Result := JSONObject;
  try
    PExpect(AParser, '{');
    PSkipWhitespace(AParser);
    if PPeek(AParser) = '}' then
    begin
      PAdvance(AParser);
      Exit;
    end;
    while True do
    begin
      PSkipWhitespace(AParser);
      if PPeek(AParser) <> '"' then
        PErrorFmt(AParser, 'expected object key string');
      name := PParseStringRaw(AParser);
      PSkipWhitespace(AParser);
      PExpect(AParser, ':');
      PSkipWhitespace(AParser);
      v := PParseValue(AParser);
      Result.AddPair(name, v);
      PSkipWhitespace(AParser);
      if PPeek(AParser) = ',' then
      begin
        PAdvance(AParser);
        Continue;
      end;
      PExpect(AParser, '}');
      Break;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function PParseValue(var AParser: TJSONParser): TJSONValue;
var
  c: Char;
begin
  PSkipWhitespace(AParser);
  c := PPeek(AParser);
  case c of
    '{': Result := PParseObject(AParser);
    '[': Result := PParseArray(AParser);
    '"': Result := JSONString(PParseStringRaw(AParser));
    't':
      begin
        if not PParseLiteral(AParser, 'true') then
          PErrorFmt(AParser, 'invalid literal');
        Result := JSONBool(True);
      end;
    'f':
      begin
        if not PParseLiteral(AParser, 'false') then
          PErrorFmt(AParser, 'invalid literal');
        Result := JSONBool(False);
      end;
    'n':
      begin
        if not PParseLiteral(AParser, 'null') then
          PErrorFmt(AParser, 'invalid literal');
        Result := JSONNull;
      end;
    '-', '0'..'9':
      Result := JSONNumber(PParseNumber(AParser));
  else
    PErrorFmt(AParser, Format('unexpected character "%s"', [c]));
    Result := nil; // unreachable
  end;
end;

function Parse(const AText: string): TJSONValue;
var
  parser: TJSONParser;
begin
  parser.Text := AText;
  parser.Pos := 1;
  parser.Len := Length(AText);
  Result := PParseValue(parser);
  try
    PSkipWhitespace(parser);
    if parser.Pos <= parser.Len then
      PErrorFmt(parser, 'trailing content after JSON value');
  except
    Result.Free;
    raise;
  end;
end;

{ ---------------- writer ---------------- }

procedure WriteEscapedString(ASb: TStringBuilder; const AValue: string);
var
  i: Integer;
  c: Char;
begin
  ASb.Append('"');
  for i := 1 to Length(AValue) do
  begin
    c := AValue[i];
    case c of
      '"':  ASb.Append('\"');
      '\':  ASb.Append('\\');
      #8:   ASb.Append('\b');
      #12:  ASb.Append('\f');
      #10:  ASb.Append('\n');
      #13:  ASb.Append('\r');
      #9:   ASb.Append('\t');
    else
      if Ord(c) < $20 then
        ASb.Append(Format('\u%.4x', [Ord(c)]))
      else
        ASb.Append(c);
    end;
  end;
  ASb.Append('"');
end;

procedure WriteValue(ASb: TStringBuilder; AValue: TJSONValue);
var
  i: Integer;
  numStr: string;
begin
  if AValue = nil then
  begin
    ASb.Append('null');
    Exit;
  end;
  case AValue.Kind of
    jkNull: ASb.Append('null');
    jkBool: if AValue.AsBool then ASb.Append('true') else ASb.Append('false');
    jkNumber:
      begin
        if AValue.AsNumber = Trunc(AValue.AsNumber) then
          numStr := IntToStr(Trunc(AValue.AsNumber))
        else
          numStr := FloatToStr(AValue.AsNumber, TFormatSettings.Invariant);
        ASb.Append(numStr);
      end;
    jkString: WriteEscapedString(ASb, AValue.AsString);
    jkArray:
      begin
        ASb.Append('[');
        for i := 0 to AValue.Count - 1 do
        begin
          if i > 0 then ASb.Append(',');
          WriteValue(ASb, AValue.Items[i]);
        end;
        ASb.Append(']');
      end;
    jkObject:
      begin
        ASb.Append('{');
        for i := 0 to AValue.Count - 1 do
        begin
          if i > 0 then ASb.Append(',');
          WriteEscapedString(ASb, AValue.Names[i]);
          ASb.Append(':');
          WriteValue(ASb, AValue.Values[i]);
        end;
        ASb.Append('}');
      end;
  end;
end;

function JSONStringify(AValue: TJSONValue): string;
var
  sb: TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    WriteValue(sb, AValue);
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function TJSONValue.ToJSONString: string;
begin
  Result := JSONStringify(Self);
end;

end.
