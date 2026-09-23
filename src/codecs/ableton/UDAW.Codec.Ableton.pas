unit UDAW.Codec.Ableton;
{$I udaw.inc}

{ Ableton Live Set (.als) importer - pure parsing, no project/timeline
  dependency (mirrors UDAW.Codec.MP3 / UDAW.Codec.FLAC / the tracker codecs'
  "parse to a plain data structure" half of the split).

  An .als file is a single-member GZIP stream wrapping a UTF-8 XML document
  (root <Ableton><LiveSet>...). Two things happen here, both from scratch:

  1. Decompression. This project's "no third-party libs" rule targets
     third-party AUDIO/JSON/XML/UI libraries (see UDAW.AI.JSON's header for
     the same point made about JSON) - it does not extend to the compiler's
     own RTL, so gzip inflate is done through System.ZLib (Delphi) /
     TGZFileStream from the zstream unit (FPC), never a hand-rolled DEFLATE
     decoder and never a vendored zlib.

  2. XML. UDAW has no XML library anywhere in the tree (grepped: no
     TXMLDocument/IXMLDocument/MSXML usage exists), so - exactly like
     UDAW.AI.JSON's hand-written JSON parser - this unit carries a small,
     from-scratch recursive-descent XML tokenizer/DOM (TXmlNode) sufficient
     for Ableton's schema: elements, attributes, nested children, comments,
     CDATA and the standard five entities plus numeric character references.
     It does not aim to be a general XML parser (no namespaces, no DTD
     validation, no external entities) - Ableton's own writer never emits
     any of that.

  Live's schema drifts across versions (9/10/11/12); this parser targets the
  layout used by Live 9.7 - 12 for tempo and the Live 11+ plain-string
  SampleRef/FileRef shape for sample paths (see docs/DAWImport-Ableton.md for
  exactly which XML paths are read and why). Older, hex-encoded FileRef
  paths (pre-11) are recognised and reported as a per-clip warning rather
  than guessed at.

  Every recoverable problem - a MIDI track (out of scope this pass), a clip
  whose sample can't be resolved, a track with no arrangement clips, a
  missing tempo - is collected into AWarnings and the import continues;
  nothing here fails the whole file for a problem local to one track or
  clip, mirroring UDAW.Codec.ProTracker's ModExportIssues pattern (a plain
  TArray<string> of human-readable notes returned alongside the result).
  Only a file that isn't gzip, or whose decompressed content isn't a
  LiveSet document at all, raises. }

interface

uses
  SysUtils, Classes, StrUtils, Generics.Collections,
  {$IFDEF FPC}
  zstream,
  {$ELSE}
  System.ZLib,
  {$ENDIF}
  UDAW.Errors;

const
  ABLETON_CODEC_SUBSYS = 'Codec.Ableton';

type
  { ---------------- minimal hand-rolled XML DOM ---------------- }

  TXmlAttr = record
    Name: string;
    Value: string;
  end;

  TXmlNode = class
  private
    FTag: string;
    FAttrs: TArray<TXmlAttr>;
    FChildren: TObjectList<TXmlNode>;
    FText: string;
    function GetChildCountImpl: Integer;
    function GetChild(AIndex: Integer): TXmlNode;
  public
    constructor Create(const ATag: string);
    destructor Destroy; override;

    procedure AddAttr(const AName, AValue: string);
    procedure AddChild(AChild: TXmlNode);   // takes ownership

    function HasAttr(const AName: string): Boolean;
    function AttrValue(const AName: string; const ADefault: string = ''): string;
    function AttrFloat(const AName: string; ADefault: Double): Double;

    { First direct child with this tag, or nil. }
    function FindChild(const ATag: string): TXmlNode;
    { First descendant (depth-first) with this tag, or nil. Searches Self's
      children and their children, never Self. }
    function FindChildRecursive(const ATag: string): TXmlNode;
    { Every descendant (depth-first, any depth) with this tag. }
    procedure CollectRecursive(const ATag: string; AOut: TList<TXmlNode>);

    property Tag: string read FTag;
    property Text: string read FText write FText;
    property ChildCount: Integer read GetChildCountImpl;
    property Children[AIndex: Integer]: TXmlNode read GetChild;
  end;

  { Parses AText (already-decompressed XML) into a tree. The caller owns the
    result and must Free it (which frees every descendant). Raises
    EUDAWError(errParse) on malformed XML. }
  function XmlParse(const AText: string): TXmlNode;

  { ---------------- Ableton domain model ---------------- }

type
  TAbletonTrackKind = (atkAudio, atkMidi, atkSkipped);

  TAbletonClip = record
    Name: string;
    StartSeconds: Double;
    LengthSeconds: Double;
    FadeInSeconds: Double;
    FadeOutSeconds: Double;
    { Absolute path to the resolved audio file. Empty means the caller
      should not have received this clip - AlsParseFile never emits a clip
      with an empty ResolvedFilePath; an unresolvable sample produces a
      warning and the clip is dropped instead. }
    ResolvedFilePath: string;
  end;

  TAbletonTrack = record
    Name: string;
    Kind: TAbletonTrackKind;
    { Only populated for Kind = atkAudio. }
    Clips: TArray<TAbletonClip>;
  end;

  TAbletonProject = record
    { Master tempo in BPM, used to convert every clip's beat-time position
      and length to seconds. Defaults to 120 (with a warning) when the set
      carries no readable Tempo/Manual value at all. }
    Tempo: Double;
    { Informational only: the raw Creator attribute off the root element,
      e.g. "Ableton Live 11.0.12". Empty if absent. }
    SourceVersion: string;
    Tracks: TArray<TAbletonTrack>;
  end;

{ True iff APath starts with the 2-byte GZIP magic (1F 8B) - the header-sniff
  convention every codec in this project uses (content, never extension). }
function AlsSniffFile(const APath: string): Boolean;

{ Decompresses and parses an .als file into AProject, collecting every
  recoverable problem into AWarnings. Returns True on success. Raises
  EUDAWError for anything that makes the file unusable as a whole (not
  gzip, corrupt gzip stream, decompressed content isn't a LiveSet document). }
function AlsParseFile(const APath: string; out AProject: TAbletonProject;
  out AWarnings: TArray<string>): Boolean;

implementation

{ ================= small helpers ================= }

function AlsStrToFloat(const S: string; ADefault: Double): Double;
begin
  if not TryStrToFloat(Trim(S), Result, TFormatSettings.Invariant) then
    Result := ADefault;
end;

{ ================= TXmlNode ================= }

constructor TXmlNode.Create(const ATag: string);
begin
  inherited Create;
  FTag := ATag;
  FChildren := TObjectList<TXmlNode>.Create(True);
end;

destructor TXmlNode.Destroy;
begin
  FChildren.Free;
  inherited Destroy;
end;

procedure TXmlNode.AddAttr(const AName, AValue: string);
var
  a: TXmlAttr;
begin
  a.Name := AName;
  a.Value := AValue;
  SetLength(FAttrs, Length(FAttrs) + 1);
  FAttrs[High(FAttrs)] := a;
end;

procedure TXmlNode.AddChild(AChild: TXmlNode);
begin
  FChildren.Add(AChild);
end;

function TXmlNode.HasAttr(const AName: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FAttrs) do
    if FAttrs[i].Name = AName then Exit(True);
  Result := False;
end;

function TXmlNode.AttrValue(const AName: string; const ADefault: string): string;
var
  i: Integer;
begin
  for i := 0 to High(FAttrs) do
    if FAttrs[i].Name = AName then Exit(FAttrs[i].Value);
  Result := ADefault;
end;

function TXmlNode.AttrFloat(const AName: string; ADefault: Double): Double;
begin
  Result := AlsStrToFloat(AttrValue(AName, ''), ADefault);
end;

function TXmlNode.FindChild(const ATag: string): TXmlNode;
var
  i: Integer;
begin
  for i := 0 to FChildren.Count - 1 do
    if FChildren[i].Tag = ATag then Exit(FChildren[i]);
  Result := nil;
end;

function TXmlNode.FindChildRecursive(const ATag: string): TXmlNode;
var
  i: Integer;
  hit: TXmlNode;
begin
  for i := 0 to FChildren.Count - 1 do
  begin
    if FChildren[i].Tag = ATag then Exit(FChildren[i]);
    hit := FChildren[i].FindChildRecursive(ATag);
    if hit <> nil then Exit(hit);
  end;
  Result := nil;
end;

procedure TXmlNode.CollectRecursive(const ATag: string; AOut: TList<TXmlNode>);
var
  i: Integer;
begin
  for i := 0 to FChildren.Count - 1 do
  begin
    if FChildren[i].Tag = ATag then AOut.Add(FChildren[i]);
    FChildren[i].CollectRecursive(ATag, AOut);
  end;
end;

function TXmlNode.GetChildCountImpl: Integer;
begin
  Result := FChildren.Count;
end;

function TXmlNode.GetChild(AIndex: Integer): TXmlNode;
begin
  Result := FChildren[AIndex];
end;

{ ================= XML tokenizer / parser ================= }

type
  TXmlParser = record
    Text: string;
    Pos: Integer;   // 1-based index of the next unread char
    Len: Integer;
  end;

procedure XErrorFmt(const AP: TXmlParser; const AReason: string);
begin
  RaiseUDAWFmt(errParse, ABLETON_CODEC_SUBSYS, 'XML parse error at position %d: %s',
    [AP.Pos, AReason]);
end;

function XPeek(const AP: TXmlParser): Char;
begin
  if AP.Pos <= AP.Len then Result := AP.Text[AP.Pos] else Result := #0;
end;

function XLooking(const AP: TXmlParser; const AWhat: string): Boolean;
begin
  Result := Copy(AP.Text, AP.Pos, Length(AWhat)) = AWhat;
end;

procedure XSkipWs(var AP: TXmlParser);
begin
  while (AP.Pos <= AP.Len) and CharInSet(AP.Text[AP.Pos], [' ', #9, #10, #13]) do
    Inc(AP.Pos);
end;

function XDecodeEntities(const S: string): string;
var
  sb: TStringBuilder;
  i, n: Integer;
  ent: string;
  semi: Integer;
  code: Integer;
begin
  if Pos('&', S) = 0 then Exit(S);
  sb := TStringBuilder.Create;
  try
    i := 1;
    n := Length(S);
    while i <= n do
    begin
      if S[i] = '&' then
      begin
        semi := PosEx(';', S, i + 1);
        if (semi > 0) and (semi - i <= 12) then
        begin
          ent := Copy(S, i + 1, semi - i - 1);
          if ent = 'amp' then begin sb.Append('&'); i := semi + 1; Continue; end
          else if ent = 'lt' then begin sb.Append('<'); i := semi + 1; Continue; end
          else if ent = 'gt' then begin sb.Append('>'); i := semi + 1; Continue; end
          else if ent = 'quot' then begin sb.Append('"'); i := semi + 1; Continue; end
          else if ent = 'apos' then begin sb.Append(''''); i := semi + 1; Continue; end
          else if (Length(ent) > 1) and (ent[1] = '#') then
          begin
            code := 0;
            if (Length(ent) > 2) and ((ent[2] = 'x') or (ent[2] = 'X')) then
            begin
              if TryStrToInt('$' + Copy(ent, 3, MaxInt), code) then
              begin
                sb.Append(Char(code));
                i := semi + 1;
                Continue;
              end;
            end
            else if TryStrToInt(Copy(ent, 2, MaxInt), code) then
            begin
              sb.Append(Char(code));
              i := semi + 1;
              Continue;
            end;
          end;
        end;
        sb.Append(S[i]);
        Inc(i);
      end
      else
      begin
        sb.Append(S[i]);
        Inc(i);
      end;
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function XParseName(var AP: TXmlParser): string;
var
  start: Integer;
begin
  start := AP.Pos;
  while (AP.Pos <= AP.Len) and
    CharInSet(AP.Text[AP.Pos], ['A'..'Z', 'a'..'z', '0'..'9', '_', '-', '.', ':'])
  do Inc(AP.Pos);
  Result := Copy(AP.Text, start, AP.Pos - start);
  if Result = '' then XErrorFmt(AP, 'expected a name');
end;

{ Skips whitespace, <?...?> processing instructions, <!--...--> comments and
  <!DOCTYPE ...> / other markup declarations, repeatedly, until none apply. }
procedure XSkipMisc(var AP: TXmlParser);
begin
  while True do
  begin
    XSkipWs(AP);
    if XLooking(AP, '<?') then
    begin
      Inc(AP.Pos, 2);
      while (AP.Pos <= AP.Len) and not XLooking(AP, '?>') do Inc(AP.Pos);
      Inc(AP.Pos, 2);
      Continue;
    end;
    if XLooking(AP, '<!--') then
    begin
      Inc(AP.Pos, 4);
      while (AP.Pos <= AP.Len) and not XLooking(AP, '-->') do Inc(AP.Pos);
      Inc(AP.Pos, 3);
      Continue;
    end;
    if XLooking(AP, '<!') then
    begin
      while (AP.Pos <= AP.Len) and (AP.Text[AP.Pos] <> '>') do Inc(AP.Pos);
      Inc(AP.Pos);
      Continue;
    end;
    Break;
  end;
end;

function XParseAttrValue(var AP: TXmlParser): string;
var
  q: Char;
  start: Integer;
begin
  q := XPeek(AP);
  if (q <> '"') and (q <> '''') then
    XErrorFmt(AP, 'expected a quoted attribute value');
  Inc(AP.Pos);
  start := AP.Pos;
  while (AP.Pos <= AP.Len) and (AP.Text[AP.Pos] <> q) do Inc(AP.Pos);
  if AP.Pos > AP.Len then
    XErrorFmt(AP, 'unterminated attribute value');
  Result := XDecodeEntities(Copy(AP.Text, start, AP.Pos - start));
  Inc(AP.Pos); // closing quote
end;

function XParseElement(var AP: TXmlParser): TXmlNode;
var
  name, attrName, closeName: string;
  c: Char;
  selfClosed: Boolean;
  textSb: TStringBuilder;
  start: Integer;
  child: TXmlNode;
begin
  if XPeek(AP) <> '<' then XErrorFmt(AP, 'expected ''<''');
  Inc(AP.Pos);
  name := XParseName(AP);
  Result := TXmlNode.Create(name);
  try
    { attributes }
    while True do
    begin
      XSkipWs(AP);
      c := XPeek(AP);
      if (c = '/') or (c = '>') or (c = #0) then Break;
      attrName := XParseName(AP);
      XSkipWs(AP);
      if XPeek(AP) <> '=' then XErrorFmt(AP, Format('expected ''='' after attribute "%s"', [attrName]));
      Inc(AP.Pos);
      XSkipWs(AP);
      Result.AddAttr(attrName, XParseAttrValue(AP));
    end;

    XSkipWs(AP);
    selfClosed := (XPeek(AP) = '/');
    if selfClosed then Inc(AP.Pos);
    if XPeek(AP) <> '>' then XErrorFmt(AP, Format('expected ''>'' closing <%s>', [name]));
    Inc(AP.Pos);
    if selfClosed then Exit;

    { children / text, up to the matching close tag }
    textSb := TStringBuilder.Create;
    try
      while True do
      begin
        if AP.Pos > AP.Len then
          XErrorFmt(AP, Format('unexpected end of document inside <%s>', [name]));
        if AP.Text[AP.Pos] = '<' then
        begin
          if XLooking(AP, '</') then
          begin
            Inc(AP.Pos, 2);
            closeName := XParseName(AP);
            XSkipWs(AP);
            if XPeek(AP) <> '>' then XErrorFmt(AP, Format('expected ''>'' closing </%s>', [closeName]));
            Inc(AP.Pos);
            if closeName <> name then
              XErrorFmt(AP, Format('mismatched closing tag </%s> for <%s>', [closeName, name]));
            Break;
          end
          else if XLooking(AP, '<!--') then
          begin
            Inc(AP.Pos, 4);
            while (AP.Pos <= AP.Len) and not XLooking(AP, '-->') do Inc(AP.Pos);
            Inc(AP.Pos, 3);
          end
          else if XLooking(AP, '<![CDATA[') then
          begin
            Inc(AP.Pos, 9);
            start := AP.Pos;
            while (AP.Pos <= AP.Len) and not XLooking(AP, ']]>') do Inc(AP.Pos);
            textSb.Append(Copy(AP.Text, start, AP.Pos - start));
            Inc(AP.Pos, 3);
          end
          else
          begin
            child := XParseElement(AP);
            Result.AddChild(child);
          end;
        end
        else
        begin
          start := AP.Pos;
          while (AP.Pos <= AP.Len) and (AP.Text[AP.Pos] <> '<') do Inc(AP.Pos);
          textSb.Append(XDecodeEntities(Copy(AP.Text, start, AP.Pos - start)));
        end;
      end;
      Result.Text := textSb.ToString;
    finally
      textSb.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function XmlParse(const AText: string): TXmlNode;
var
  p: TXmlParser;
begin
  p.Text := AText;
  p.Pos := 1;
  p.Len := Length(AText);
  XSkipMisc(p);
  if XPeek(p) <> '<' then
    XErrorFmt(p, 'document does not start with an XML element');
  Result := XParseElement(p);
end;

{ ================= gzip decompression ================= }

function AlsSniffFile(const APath: string): Boolean;
var
  fs: TFileStream;
  hdr: array[0..1] of Byte;
begin
  Result := False;
  if not FileExists(APath) then Exit;
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    if fs.Size < 2 then Exit;
    fs.ReadBuffer(hdr, 2);
    Result := (hdr[0] = $1F) and (hdr[1] = $8B);
  finally
    fs.Free;
  end;
end;

{ Decompresses the single-member GZIP stream at APath into raw bytes.
  Delphi: System.ZLib's TZDecompressionStream, windowBits = 15 + 16 (the
  zlib-documented "add 16 to write/read a gzip header+trailer instead of a
  zlib wrapper" convention - see System.ZLib.pas's deflateInit2 comment).
  FPC: TGZFileStream from the zstream unit, which reads an actual on-disk
  .gz file directly (an .als file, unpacked, is exactly that), so no manual
  header handling is needed on either leg. }
function AlsGunzipToBytes(const APath: string): TBytes;
const
  BUF_SIZE = 65536;
var
  ms: TMemoryStream;
  buf: array[0..BUF_SIZE - 1] of Byte;
  n: Integer;
  {$IFDEF FPC}
  gz: TGZFileStream;
  {$ELSE}
  fs: TFileStream;
  zs: TZDecompressionStream;
  {$ENDIF}
begin
  ms := TMemoryStream.Create;
  try
    {$IFDEF FPC}
    gz := TGZFileStream.Create(APath, gzopenread);
    try
      repeat
        n := gz.Read(buf, BUF_SIZE);
        if n > 0 then ms.WriteBuffer(buf, n);
      until n <= 0;
    finally
      gz.Free;
    end;
    {$ELSE}
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
    try
      zs := TZDecompressionStream.Create(fs, 15 + 16);
      try
        repeat
          n := zs.Read(buf, BUF_SIZE);
          if n > 0 then ms.WriteBuffer(buf, n);
        until n <= 0;
      finally
        zs.Free;
      end;
    finally
      fs.Free;
    end;
    {$ENDIF}
    SetLength(Result, ms.Size);
    if ms.Size > 0 then
      Move(ms.Memory^, Result[0], ms.Size);
  finally
    ms.Free;
  end;
end;

{ ================= Ableton domain extraction ================= }

function AlsClipName(AClip: TXmlNode): string;
var
  n: TXmlNode;
begin
  n := AClip.FindChild('Name');
  if n <> nil then Result := n.AttrValue('Value', '') else Result := '';
  if Result = '' then Result := '(unnamed clip)';
end;

function AlsTrackName(ATrack: TXmlNode; ADefault: string): string;
var
  nameNode, sub: TXmlNode;
begin
  Result := '';
  nameNode := ATrack.FindChild('Name');
  if nameNode <> nil then
  begin
    sub := nameNode.FindChild('UserName');
    if sub <> nil then Result := sub.AttrValue('Value', '');
    if Result = '' then
    begin
      sub := nameNode.FindChild('EffectiveName');
      if sub <> nil then Result := sub.AttrValue('Value', '');
    end;
  end;
  if Result = '' then Result := ADefault;
end;

{ Beats -> seconds, given the project tempo in BPM. }
function AlsBeatsToSeconds(ABeats, ATempoBpm: Double): Double;
begin
  if ATempoBpm <= 0 then ATempoBpm := 120;
  Result := ABeats * (60.0 / ATempoBpm);
end;

{ Reads CurrentStart/CurrentEnd (beat positions, absolute in the arrangement -
  confirmed by Transport.furthest_bar reading raw CurrentEnd values as
  absolute bar positions in the well-documented abletoolz parser this was
  cross-checked against). Falls back to the clip's own Time attribute plus a
  Loop-marker span when CurrentStart/CurrentEnd are absent. Returns False
  (no usable length) rather than guessing. }
function AlsClipBeatSpan(AClip: TXmlNode; out AStartBeats, AEndBeats: Double): Boolean;
var
  csNode, ceNode, loopNode, lsNode, leNode: TXmlNode;
  timeAttr: Double;
begin
  csNode := AClip.FindChild('CurrentStart');
  ceNode := AClip.FindChild('CurrentEnd');
  if (csNode <> nil) and (ceNode <> nil) then
  begin
    AStartBeats := csNode.AttrFloat('Value', 0);
    AEndBeats := ceNode.AttrFloat('Value', AStartBeats);
    Exit(AEndBeats > AStartBeats);
  end;

  timeAttr := AClip.AttrFloat('Time', 0);
  loopNode := AClip.FindChild('Loop');
  if loopNode <> nil then
  begin
    lsNode := loopNode.FindChild('LoopStart');
    leNode := loopNode.FindChild('LoopEnd');
    if (lsNode <> nil) and (leNode <> nil) then
    begin
      AStartBeats := timeAttr;
      AEndBeats := timeAttr + (leNode.AttrFloat('Value', 0) - lsNode.AttrFloat('Value', 0));
      Exit(AEndBeats > AStartBeats);
    end;
  end;

  AStartBeats := timeAttr;
  AEndBeats := timeAttr;
  Result := False;
end;

{ Best-effort fade lengths (beats) from directly under the clip - Live 9/10
  write FadeInLength/FadeOutLength as direct children; later versions nest
  fade data under a Fades subtree with the same leaf names. Anything else
  about Fades (curve shape, per-channel fades) is out of scope. }
procedure AlsClipFades(AClip: TXmlNode; ATempoBpm: Double;
  out AFadeInSeconds, AFadeOutSeconds: Double);
var
  n: TXmlNode;
begin
  AFadeInSeconds := 0;
  AFadeOutSeconds := 0;
  n := AClip.FindChildRecursive('FadeInLength');
  if n <> nil then AFadeInSeconds := AlsBeatsToSeconds(n.AttrFloat('Value', 0), ATempoBpm);
  n := AClip.FindChildRecursive('FadeOutLength');
  if n <> nil then AFadeOutSeconds := AlsBeatsToSeconds(n.AttrFloat('Value', 0), ATempoBpm);
  if AFadeInSeconds < 0 then AFadeInSeconds := 0;
  if AFadeOutSeconds < 0 then AFadeOutSeconds := 0;
end;

function AlsJoinRelative(const ABaseDir, ARelative: string): string;
var
  rel: string;
begin
  rel := StringReplace(ARelative, '/', PathDelim, [rfReplaceAll]);
  rel := StringReplace(rel, '\', PathDelim, [rfReplaceAll]);
  while (Length(rel) > 0) and (rel[1] = PathDelim) do Delete(rel, 1, 1);
  Result := IncludeTrailingPathDelimiter(ABaseDir) + rel;
end;

{ Resolves one clip's sample file. Only the Live 11+ plain-string
  SampleRef/FileRef shape (Path / RelativePath as string attributes) is
  supported - see the unit header. Resolution order, per the task brief:
  relative to the .als file's own directory, then relative to the project's
  parent folder (the common "<Project>\Samples\Imported\..." layout when
  the set itself sits in "<Project>\<SetName>.als"), then the absolute path
  the set recorded. Returns '' (with AWarning describing why) if none exist. }
function AlsResolveSample(AClip: TXmlNode; const AAlsDir: string;
  out AWarning: string): string;
var
  sampleRef, fileRef, pathNode, relNode, dataNode: TXmlNode;
  absPath, relPath, tryPath, projectParent: string;
  clipName: string;
begin
  Result := '';
  AWarning := '';
  clipName := AlsClipName(AClip);

  sampleRef := AClip.FindChild('SampleRef');
  if sampleRef = nil then
  begin
    AWarning := Format('clip "%s" has no SampleRef; skipped', [clipName]);
    Exit;
  end;
  fileRef := sampleRef.FindChild('FileRef');
  if fileRef = nil then
  begin
    AWarning := Format('clip "%s" has a SampleRef with no FileRef; skipped', [clipName]);
    Exit;
  end;

  pathNode := fileRef.FindChild('Path');
  if pathNode = nil then
  begin
    { Pre-Live-11 sets hex-encode the absolute path inside a <Data> element
      instead of a plain <Path Value="..."/> - that legacy shape is out of
      scope for this pass (see unit header / docs/DAWImport-Ableton.md). }
    dataNode := fileRef.FindChild('Data');
    if dataNode <> nil then
      AWarning := Format(
        'clip "%s": pre-Live-11 (hex-encoded) sample reference format is not supported; skipped',
        [clipName])
    else
      AWarning := Format('clip "%s": FileRef carries no Path; skipped', [clipName]);
    Exit;
  end;
  absPath := pathNode.AttrValue('Value', '');

  relPath := '';
  relNode := fileRef.FindChild('RelativePath');
  if relNode <> nil then
    relPath := relNode.AttrValue('Value', '');

  if relPath <> '' then
  begin
    tryPath := AlsJoinRelative(AAlsDir, relPath);
    if FileExists(tryPath) then Exit(tryPath);

    projectParent := ExtractFilePath(ExcludeTrailingPathDelimiter(AAlsDir));
    if projectParent <> '' then
    begin
      tryPath := AlsJoinRelative(projectParent, relPath);
      if FileExists(tryPath) then Exit(tryPath);
    end;
  end;

  if (absPath <> '') and FileExists(absPath) then Exit(absPath);

  AWarning := Format(
    'sample not found for clip "%s" (tried relative "%s" under the project folder, ' +
    'and absolute "%s"); clip skipped',
    [clipName, relPath, absPath]);
  Result := '';
end;

{ Counts warp-marker / automation-envelope elements anywhere under a track,
  purely for the one-line-per-track "N automation/warp features not
  imported" warning the task brief calls for - no attempt is made to
  interpret or preserve any of it. }
function AlsCountUnimportedFeatures(ATrack: TXmlNode): Integer;
var
  list: TList<TXmlNode>;
begin
  list := TList<TXmlNode>.Create;
  try
    ATrack.CollectRecursive('WarpMarker', list);
    Result := list.Count;
    list.Clear;
    ATrack.CollectRecursive('FloatEvent', list);
    Inc(Result, list.Count);
    list.Clear;
    ATrack.CollectRecursive('AutomationEnvelope', list);
    Inc(Result, list.Count);
  finally
    list.Free;
  end;
end;

procedure AlsExtractAudioTrack(ATrack: TXmlNode; ATempoBpm: Double;
  const AAlsDir: string; var AResult: TAbletonTrack; AWarnings: TStringList);
var
  mainSeq, sampleNode: TXmlNode;
  clipNodes: TList<TXmlNode>;
  clips: TList<TAbletonClip>;
  i: Integer;
  clipEl: TXmlNode;
  startBeats, endBeats: Double;
  clip: TAbletonClip;
  warn, resolved: string;
  featureCount: Integer;
begin
  AResult.Name := AlsTrackName(ATrack, 'Audio');
  AResult.Kind := atkAudio;
  SetLength(AResult.Clips, 0);

  mainSeq := ATrack.FindChildRecursive('MainSequencer');
  if mainSeq <> nil then
    sampleNode := mainSeq.FindChildRecursive('Sample')
  else
    sampleNode := ATrack.FindChildRecursive('Sample');

  if sampleNode = nil then
  begin
    { No nested arrangement content at all - not an error, just a track
      with nothing to import (matches the task brief: absence of an
      expected nested element means "no arrangement clips", not failure). }
  end
  else
  begin
    clipNodes := TList<TXmlNode>.Create;
    clips := TList<TAbletonClip>.Create;
    try
      sampleNode.CollectRecursive('AudioClip', clipNodes);
      for i := 0 to clipNodes.Count - 1 do
      begin
        clipEl := clipNodes[i];
        if not AlsClipBeatSpan(clipEl, startBeats, endBeats) then
        begin
          AWarnings.Add(Format('track "%s": clip "%s" has no determinable length; skipped',
            [AResult.Name, AlsClipName(clipEl)]));
          Continue;
        end;

        resolved := AlsResolveSample(clipEl, AAlsDir, warn);
        if resolved = '' then
        begin
          if warn <> '' then AWarnings.Add(Format('track "%s": %s', [AResult.Name, warn]));
          Continue;
        end;

        clip.Name := AlsClipName(clipEl);
        clip.StartSeconds := AlsBeatsToSeconds(startBeats, ATempoBpm);
        clip.LengthSeconds := AlsBeatsToSeconds(endBeats - startBeats, ATempoBpm);
        AlsClipFades(clipEl, ATempoBpm, clip.FadeInSeconds, clip.FadeOutSeconds);
        clip.ResolvedFilePath := resolved;
        clips.Add(clip);
      end;
      AResult.Clips := clips.ToArray;
    finally
      clips.Free;
      clipNodes.Free;
    end;
  end;

  featureCount := AlsCountUnimportedFeatures(ATrack);
  if featureCount > 0 then
    AWarnings.Add(Format('track "%s": %d automation/warp feature(s) not imported',
      [AResult.Name, featureCount]));
end;

function AlsFindTempo(ALiveSet: TXmlNode; AWarnings: TStringList): Double;
var
  masterTrack, tempoNode, manualNode: TXmlNode;
begin
  tempoNode := nil;
  masterTrack := ALiveSet.FindChild('MasterTrack');
  if masterTrack <> nil then
    tempoNode := masterTrack.FindChildRecursive('Tempo');
  if tempoNode = nil then
    tempoNode := ALiveSet.FindChild('Tempo');

  if tempoNode <> nil then
  begin
    manualNode := tempoNode.FindChild('Manual');
    if manualNode <> nil then
    begin
      Result := manualNode.AttrFloat('Value', -1);
      if Result > 0 then Exit;
    end;
  end;

  AWarnings.Add('project tempo not found; assuming 120 BPM');
  Result := 120;
end;

function AlsParseFile(const APath: string; out AProject: TAbletonProject;
  out AWarnings: TArray<string>): Boolean;
var
  bytes: TBytes;
  xml: string;
  root, liveSet, tracksNode: TXmlNode;
  warnList: TStringList;
  tracks: TList<TAbletonTrack>;
  i: Integer;
  trackEl: TXmlNode;
  trk: TAbletonTrack;
  midiCount, otherCount: Integer;
begin
  AProject.Tempo := 0;
  AProject.SourceVersion := '';
  SetLength(AProject.Tracks, 0);
  SetLength(AWarnings, 0);

  if not FileExists(APath) then
    RaiseUDAWFmt(errFileNotFound, ABLETON_CODEC_SUBSYS, 'Ableton Live Set not found: %s', [APath]);
  if not AlsSniffFile(APath) then
    RaiseUDAWFmt(errConfig, ABLETON_CODEC_SUBSYS,
      'not a GZIP-compressed Ableton Live Set: %s', [APath]);

  try
    bytes := AlsGunzipToBytes(APath);
  except
    on E: Exception do
      RaiseUDAWFmt(errIO, ABLETON_CODEC_SUBSYS,
        'could not decompress "%s": %s', [APath, E.Message]);
  end;
  if Length(bytes) = 0 then
    RaiseUDAWFmt(errParse, ABLETON_CODEC_SUBSYS, 'decompressed to no data: %s', [APath]);

  xml := TEncoding.UTF8.GetString(bytes);

  root := XmlParse(xml);
  warnList := TStringList.Create;
  tracks := TList<TAbletonTrack>.Create;
  try
    if root.Tag <> 'Ableton' then
      RaiseUDAWFmt(errParse, ABLETON_CODEC_SUBSYS,
        'not an Ableton Live Set document (root is <%s>): %s', [root.Tag, APath]);
    AProject.SourceVersion := root.AttrValue('Creator', '');

    liveSet := root.FindChild('LiveSet');
    if liveSet = nil then
      RaiseUDAWFmt(errParse, ABLETON_CODEC_SUBSYS, 'no <LiveSet> element: %s', [APath]);

    AProject.Tempo := AlsFindTempo(liveSet, warnList);

    tracksNode := liveSet.FindChild('Tracks');
    if tracksNode = nil then
      warnList.Add('project has no <Tracks> element; nothing to import')
    else
    begin
      midiCount := 0;
      otherCount := 0;
      for i := 0 to tracksNode.ChildCount - 1 do
      begin
        trackEl := tracksNode.Children[i];
        if trackEl.Tag = 'AudioTrack' then
        begin
          AlsExtractAudioTrack(trackEl, AProject.Tempo,
            ExtractFilePath(ExpandFileName(APath)), trk, warnList);
          tracks.Add(trk);
        end
        else if trackEl.Tag = 'MidiTrack' then
        begin
          Inc(midiCount);
          trk.Name := AlsTrackName(trackEl, 'MIDI');
          trk.Kind := atkMidi;
          SetLength(trk.Clips, 0);
          tracks.Add(trk);
        end
        else
        begin
          { ReturnTrack / GroupTrack / PreHearTrack / anything else this
            parser doesn't recognise: not audio, not MIDI, just skipped. }
          Inc(otherCount);
          trk.Name := AlsTrackName(trackEl, trackEl.Tag);
          trk.Kind := atkSkipped;
          SetLength(trk.Clips, 0);
          tracks.Add(trk);
        end;
      end;
      if midiCount > 0 then
        warnList.Add(Format(
          '%d MIDI track(s) skipped (MIDI/instrument import is out of scope for this pass)',
          [midiCount]));
      if otherCount > 0 then
        warnList.Add(Format('%d non-audio/MIDI track(s) skipped (return/group/other)', [otherCount]));
    end;

    AProject.Tracks := tracks.ToArray;
    SetLength(AWarnings, warnList.Count);
    for i := 0 to warnList.Count - 1 do
      AWarnings[i] := warnList[i];
    Result := True;
  finally
    tracks.Free;
    warnList.Free;
    root.Free;
  end;
end;

end.
