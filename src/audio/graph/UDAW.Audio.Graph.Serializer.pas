unit UDAW.Audio.Graph.Serializer;
{$I udaw.inc}

{ Phase 4 - a small, versioned, human-readable text serializer for TAudioGraph.

  It never deserializes raw class memory: every line is parsed field by field,
  the version is checked, unknown node kinds are rejected, and node ids from
  the file are validated for uniqueness before any connection is resolved.

  Format (line-oriented, '#' comments and blank lines ignored):

    UDAWGRAPH 1
    CHANNELS 2
    NODE 1 source "Osc" shape=sine;freq=440;amp=0.5
    NODE 2 gain "Trim" db=-6
    NODE 3 output "Master" db=0;bypass=0;mute=0
    CONN 1 2
    CONN 2 3

  The parameter field is a single whitespace-free key=value;... token; the two
  boolean flags bypass / mute travel inside it. }

interface

uses
  SysUtils, Classes,
  UDAW.Errors,
  UDAW.Audio.Graph, UDAW.Audio.Graph.Nodes;

const
  GRAPH_FILE_MAGIC   = 'UDAWGRAPH';
  GRAPH_FILE_VERSION = 1;

{ Serialize an already-built graph. Does not require a compiled plan. }
function GraphToString(AGraph: TAudioGraph): string;

{ Parse text into a new graph (caller owns the result). Raises EUDAWError
  (errConfig) on a malformed or unsupported document. }
function GraphFromString(const AText: string): TAudioGraph;

procedure GraphToFile(AGraph: TAudioGraph; const AFileName: string);
function GraphFromFile(const AFileName: string): TAudioGraph;

implementation

function QuoteName(const S: string): string;
begin
  Result := '"' + StringReplace(S, '"', '''', [rfReplaceAll]) + '"';
end;

function MergeFlags(const AParams: string; ABypass, AMute: Boolean): string;
begin
  Result := AParams;
  if ABypass then
  begin
    if Result <> '' then Result := Result + ';';
    Result := Result + 'bypass=1';
  end;
  if AMute then
  begin
    if Result <> '' then Result := Result + ';';
    Result := Result + 'mute=1';
  end;
  if Result = '' then Result := '-';
end;

function GraphToString(AGraph: TAudioGraph): string;
var
  sb: TStringBuilder;
  i: Integer;
  n: TAudioNode;
  c: TGraphConn;
begin
  sb := TStringBuilder.Create;
  try
    sb.Append(GRAPH_FILE_MAGIC).Append(' ').Append(GRAPH_FILE_VERSION).AppendLine;
    sb.Append('CHANNELS ').Append(AGraph.Channels).AppendLine;
    for i := 0 to AGraph.NodeCount - 1 do
    begin
      n := AGraph.GetNode(i);
      sb.Append('NODE ').Append(n.Id).Append(' ')
        .Append(NodeKindId(n.Kind)).Append(' ')
        .Append(QuoteName(n.Name)).Append(' ')
        .Append(MergeFlags(n.SerializeParams, n.Bypass, n.Mute)).AppendLine;
    end;
    for i := 0 to AGraph.ConnectionCount - 1 do
    begin
      c := AGraph.GetConnection(i);
      sb.Append('CONN ').Append(c.FromId).Append(' ').Append(c.ToId).AppendLine;
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

{ pull a leading "quoted" token off S (S is advanced past it and any gap) }
function TakeQuoted(var S: string): string;
var
  i, closeAt: Integer;
begin
  S := TrimLeft(S);
  if (S = '') or (S[1] <> '"') then
    RaiseUDAW(errConfig, GRAPH_SUBSYS, 'graph parse: expected a quoted name');
  closeAt := 0;
  for i := 2 to Length(S) do
    if S[i] = '"' then begin closeAt := i; Break; end;
  if closeAt = 0 then
    RaiseUDAW(errConfig, GRAPH_SUBSYS, 'graph parse: unterminated quoted name');
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

function GraphFromString(const AText: string): TAudioGraph;
var
  lines: TStringList;
  li, ver, chans, fromId, toId, nodeId: Integer;
  raw, line, tok, kindId, nm, params: string;
  kind: TNodeKind;
  g: TAudioGraph;
  node: TAudioNode;
  haveHeader: Boolean;
begin
  lines := TStringList.Create;
  g := nil;
  try
    lines.Text := AText;
    haveHeader := False;
    chans := 2;
    ver := 0;

    for li := 0 to lines.Count - 1 do
    begin
      raw := Trim(lines[li]);
      if (raw = '') or (raw[1] = '#') then Continue;

      if not haveHeader then
      begin
        line := raw;
        tok := TakeToken(line);
        if not SameText(tok, GRAPH_FILE_MAGIC) then
          RaiseUDAW(errConfig, GRAPH_SUBSYS,
            'not a UDAW graph document (missing ' + GRAPH_FILE_MAGIC + ' header)');
        if not TryStrToInt(Trim(line), ver) then
          RaiseUDAW(errConfig, GRAPH_SUBSYS, 'graph header: missing version number');
        if (ver <= 0) or (ver > GRAPH_FILE_VERSION) then
          RaiseUDAWFmt(errConfig, GRAPH_SUBSYS,
            'unsupported graph document version %d (reader supports up to %d)',
            [ver, GRAPH_FILE_VERSION]);
        haveHeader := True;
        Continue;
      end;

      line := raw;
      tok := TakeToken(line);

      if SameText(tok, 'CHANNELS') then
      begin
        if not TryStrToInt(Trim(line), chans) then
          RaiseUDAW(errConfig, GRAPH_SUBSYS, 'CHANNELS: not an integer');
        if g = nil then
          g := TAudioGraph.Create(chans);
      end
      else if SameText(tok, 'NODE') then
      begin
        if g = nil then g := TAudioGraph.Create(chans);
        tok := TakeToken(line);
        if not TryStrToInt(tok, nodeId) then
          RaiseUDAW(errConfig, GRAPH_SUBSYS, 'NODE: bad id');
        kindId := TakeToken(line);
        if not NodeKindFromId(kindId, kind) then
          RaiseUDAWFmt(errConfig, GRAPH_SUBSYS, 'NODE: unknown kind "%s"', [kindId]);
        nm := TakeQuoted(line);
        params := Trim(line);
        if params = '-' then params := '';
        node := g.AddNodeWithId(nodeId, kind, nm);
        node.DeserializeParams(params);
        node.Bypass := ParamBool(params, 'bypass', False);
        node.Mute := ParamBool(params, 'mute', False);
      end
      else if SameText(tok, 'CONN') then
      begin
        if g = nil then
          RaiseUDAW(errConfig, GRAPH_SUBSYS, 'CONN before any NODE');
        tok := TakeToken(line);
        if not TryStrToInt(tok, fromId) then
          RaiseUDAW(errConfig, GRAPH_SUBSYS, 'CONN: bad source id');
        if not TryStrToInt(Trim(line), toId) then
          RaiseUDAW(errConfig, GRAPH_SUBSYS, 'CONN: bad target id');
        g.Connect(fromId, toId);
      end
      else
        RaiseUDAWFmt(errConfig, GRAPH_SUBSYS, 'graph parse: unexpected line "%s"', [raw]);
    end;

    if not haveHeader then
      RaiseUDAW(errConfig, GRAPH_SUBSYS, 'empty or headerless graph document');
    if g = nil then
      g := TAudioGraph.Create(chans);

    Result := g;
    g := nil;
  finally
    lines.Free;
    g.Free;   // only non-nil if we raised before handing ownership over
  end;
end;

procedure GraphToFile(AGraph: TAudioGraph; const AFileName: string);
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  try
    sl.Text := GraphToString(AGraph);
    sl.SaveToFile(AFileName);
  finally
    sl.Free;
  end;
end;

function GraphFromFile(const AFileName: string): TAudioGraph;
var
  sl: TStringList;
begin
  if not FileExists(AFileName) then
    RaiseUDAWFmt(errFileNotFound, GRAPH_SUBSYS, 'graph file not found: %s', [AFileName]);
  sl := TStringList.Create;
  try
    sl.LoadFromFile(AFileName);
    Result := GraphFromString(sl.Text);
  finally
    sl.Free;
  end;
end;

end.
