unit UDAW.Codec.MP4.Atoms;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 16 - MP4 support (plan section 19).  The ISO Base Media File Format
  (ISO/IEC 14496-12) *box layer*, treated strictly as a container: this unit
  knows nothing about any audio codec.  It provides

    * big-endian scalar readers over a byte buffer, every one bounds checked;
    * TMP4Atom - one parsed box (type, byte range, 64-bit-size aware, UUID
      extended type) and its children, built lazily by RecurseInto for the
      container boxes that are known to hold only child boxes;
    * a whole-buffer parse (ParseAtomTree) that never trusts a length field -
      a box whose declared size runs past its parent is clamped and flagged,
      never used to steer an allocation or a read;
    * TMP4BoxWriter - the mirror image: an append-only builder that emits
      correctly sized boxes (32-bit, or 64-bit large-size when needed) so the
      writer in UDAW.Codec.MP4.Container can assemble ftyp/moov/mdat from
      scratch.

  "MP4" here is the container.  What audio it carries (AAC, ALAC, MP3, PCM,
  ...) is decided in UDAW.Codec.MP4.Container from the sample-description box
  and reported separately - this unit never labels the container as a codec. }

interface

uses
  SysUtils, Classes,
  UDAW.Errors;

const
  MP4_SUBSYS = 'Codec.MP4';

  { Allocation guard rails. }
  MP4_MAX_FILE_BYTES  = Int64(4) * 1024 * 1024 * 1024;   // 4 GiB
  MP4_MAX_ATOMS       = 512 * 1024;
  MP4_MAX_DEPTH       = 32;
  MP4_MAX_TABLE_ENTRIES = 64 * 1024 * 1024;              // stsz/stco/... entry cap

type
  { A FourCC as a readable string plus its raw 32-bit form. }
  TFourCC = record
    Text: string;          // 4 printable-ish chars
    Value: Cardinal;       // big-endian packed
    class function Make(const AText: string): TFourCC; static;
    class function FromBytes(B0, B1, B2, B3: Byte): TFourCC; static;
    function Equals(const AText: string): Boolean;
  end;

  TMP4Atom = class;
  TMP4AtomList = TArray<TMP4Atom>;

  TMP4Atom = class
  private
    FKind: TFourCC;
    FHeaderOffset: Int64;    // start of the box, i.e. the size field
    FHeaderSize: Integer;    // 8, or 16 with 64-bit largesize, +16 more for uuid
    FContentOffset: Int64;   // first payload byte after the header
    FContentSize: Int64;     // payload byte count (already clamped to the buffer)
    FDeclaredSize: Int64;    // raw size the file claimed (0 / 1 resolved)
    FTruncated: Boolean;     // declared size ran past the parent / buffer
    FUserType: TBytes;       // 16 bytes when Kind = 'uuid'
    FChildren: TMP4AtomList;
    FParsedChildren: Boolean;
  public
    destructor Destroy; override;
    function ChildCount: Integer;
    function Child(AIndex: Integer): TMP4Atom;
    { first child of the given type, or nil }
    function Find(const AType: string): TMP4Atom;
    { every child of the given type }
    function FindAll(const AType: string): TMP4AtomList;
    { walk a slash path, e.g. Path('mdia/minf/stbl/stsd'); nil if any hop misses }
    function Path(const ASlashPath: string): TMP4Atom;
    property Kind: TFourCC read FKind;
    property HeaderOffset: Int64 read FHeaderOffset;
    property HeaderSize: Integer read FHeaderSize;
    property ContentOffset: Int64 read FContentOffset;
    property ContentSize: Int64 read FContentSize;
    property DeclaredSize: Int64 read FDeclaredSize;
    property Truncated: Boolean read FTruncated;
    property UserType: TBytes read FUserType;
    property Children: TMP4AtomList read FChildren;
  end;

  { The parsed file: a synthetic root whose children are the top-level boxes. }
  TMP4AtomTree = class
  private
    FData: TBytes;
    FRoot: TMP4Atom;
    FAtomCount: Integer;
    procedure ParseRange(AParent: TMP4Atom; AStart, AEnd: Int64; ADepth: Integer);
  public
    constructor Create(const AData: TBytes);
    destructor Destroy; override;
    property Root: TMP4Atom read FRoot;
    property Data: TBytes read FData;
    property AtomCount: Integer read FAtomCount;
    { copy a box's payload out as a fresh buffer }
    function ContentBytes(AAtom: TMP4Atom): TBytes;
    function Describe: string;
  end;

{ Container box types whose payload is purely child boxes (so ParseAtomTree
  recurses).  Everything else is treated as a leaf and left for the codec /
  container layer to interpret. }
function IsContainerBox(const AType: string): Boolean;

{ ---- big-endian scalar reads (bounds checked; raise errIO on overrun) ---- }
function BE_U8 (const B: TBytes; AOfs: Int64): Byte;
function BE_U16(const B: TBytes; AOfs: Int64): Word;
function BE_U24(const B: TBytes; AOfs: Int64): Cardinal;
function BE_U32(const B: TBytes; AOfs: Int64): Cardinal;
function BE_U64(const B: TBytes; AOfs: Int64): UInt64;
function BE_S16(const B: TBytes; AOfs: Int64): SmallInt;
{ 16.16 / 8.8 fixed point as used by tkhd/mvhd/smhd }
function BE_Fixed1616(const B: TBytes; AOfs: Int64): Double;
function BE_Fixed88(const B: TBytes; AOfs: Int64): Double;
function ReadFourCC(const B: TBytes; AOfs: Int64): TFourCC;

{ safe substring: returns '' rather than raising }
function SafeAscii(const B: TBytes; AOfs, ALen: Int64): string;

type
  { Append-only big-endian writer used to build boxes from scratch. }
  TMP4BoxWriter = class
  private
    FStream: TBytesStream;
    FStack: array of Int64;    // offsets of open box size fields
    FStackTop: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure U8(AValue: Byte);
    procedure U16(AValue: Word);
    procedure U24(AValue: Cardinal);
    procedure U32(AValue: Cardinal);
    procedure U64(AValue: UInt64);
    procedure S16(AValue: SmallInt);
    procedure Fixed1616(AValue: Double);
    procedure Fixed88(AValue: Double);
    procedure FourCCStr(const AText: string);
    procedure RawBytes(const B: TBytes); overload;
    procedure RawBytes(const B; ALen: Integer); overload;
    procedure Zeros(ACount: Integer);
    procedure AsciiZ(const AText: string);        // bytes, no terminator
    { open a box of the given type; call CloseBox to backpatch its size }
    procedure BeginBox(const AType: string);
    procedure BeginFullBox(const AType: string; AVersion: Byte; AFlags: Cardinal);
    procedure CloseBox;
    function Position: Int64;
    function ToBytes: TBytes;
    { total nesting still open - must be 0 before ToBytes }
    property OpenBoxes: Integer read FStackTop;
  end;

implementation

{ ============================ TFourCC ================================= }

class function TFourCC.Make(const AText: string): TFourCC;
var
  s: AnsiString;
  i: Integer;
begin
  s := AnsiString(AText);
  while Length(s) < 4 do s := s + ' ';
  Result.Text := string(Copy(s, 1, 4));
  Result.Value := 0;
  for i := 1 to 4 do
    Result.Value := (Result.Value shl 8) or Byte(s[i]);
end;

class function TFourCC.FromBytes(B0, B1, B2, B3: Byte): TFourCC;
  function Vis(B: Byte): Char;
  begin
    if (B >= 32) and (B < 127) then Result := Chr(B) else Result := '.';
  end;
begin
  Result.Value := (Cardinal(B0) shl 24) or (Cardinal(B1) shl 16) or
                  (Cardinal(B2) shl 8) or Cardinal(B3);
  Result.Text := Vis(B0) + Vis(B1) + Vis(B2) + Vis(B3);
end;

function TFourCC.Equals(const AText: string): Boolean;
begin
  Result := SameText(Trim(Text), Trim(AText)) or (Text = AText);
end;

{ ============================ scalar reads =========================== }

procedure NeedBytes(const B: TBytes; AOfs, ACount: Int64);
begin
  if (AOfs < 0) or (AOfs + ACount > Length(B)) then
    RaiseUDAWFmt(errIO, MP4_SUBSYS,
      'MP4 read past end of buffer (ofs %d + %d > %d)', [AOfs, ACount, Length(B)]);
end;

function BE_U8(const B: TBytes; AOfs: Int64): Byte;
begin
  NeedBytes(B, AOfs, 1);
  Result := B[AOfs];
end;

function BE_U16(const B: TBytes; AOfs: Int64): Word;
begin
  NeedBytes(B, AOfs, 2);
  Result := (Word(B[AOfs]) shl 8) or Word(B[AOfs + 1]);
end;

function BE_U24(const B: TBytes; AOfs: Int64): Cardinal;
begin
  NeedBytes(B, AOfs, 3);
  Result := (Cardinal(B[AOfs]) shl 16) or (Cardinal(B[AOfs + 1]) shl 8) or
            Cardinal(B[AOfs + 2]);
end;

function BE_U32(const B: TBytes; AOfs: Int64): Cardinal;
begin
  NeedBytes(B, AOfs, 4);
  Result := (Cardinal(B[AOfs]) shl 24) or (Cardinal(B[AOfs + 1]) shl 16) or
            (Cardinal(B[AOfs + 2]) shl 8) or Cardinal(B[AOfs + 3]);
end;

function BE_U64(const B: TBytes; AOfs: Int64): UInt64;
begin
  NeedBytes(B, AOfs, 8);
  Result := (UInt64(BE_U32(B, AOfs)) shl 32) or UInt64(BE_U32(B, AOfs + 4));
end;

function BE_S16(const B: TBytes; AOfs: Int64): SmallInt;
begin
  Result := SmallInt(BE_U16(B, AOfs));
end;

function BE_Fixed1616(const B: TBytes; AOfs: Int64): Double;
begin
  Result := Integer(BE_U32(B, AOfs)) / 65536.0;
end;

function BE_Fixed88(const B: TBytes; AOfs: Int64): Double;
begin
  Result := SmallInt(BE_U16(B, AOfs)) / 256.0;
end;

function ReadFourCC(const B: TBytes; AOfs: Int64): TFourCC;
begin
  NeedBytes(B, AOfs, 4);
  Result := TFourCC.FromBytes(B[AOfs], B[AOfs + 1], B[AOfs + 2], B[AOfs + 3]);
end;

function SafeAscii(const B: TBytes; AOfs, ALen: Int64): string;
var
  i: Int64;
  c: Byte;
begin
  Result := '';
  if AOfs < 0 then Exit;
  for i := AOfs to AOfs + ALen - 1 do
  begin
    if i >= Length(B) then Break;
    c := B[i];
    if c = 0 then Break;
    if (c >= 32) and (c < 127) then
      Result := Result + Chr(c)
    else
      Result := Result + '?';
  end;
end;

{ ============================ container set ========================== }

function IsContainerBox(const AType: string): Boolean;
const
  CONT: array[0..21] of string = (
    'moov', 'trak', 'mdia', 'minf', 'stbl', 'edts', 'dinf',
    'mvex', 'moof', 'traf', 'mfra', 'udta', 'meta', 'ipro',
    'sinf', 'schi', 'stsd', 'wave', 'ilst', 'tref', 'gmhd', '----');
var
  i: Integer;
begin
  { NB: 'meta' is a FullBox (4 extra bytes before children) and 'stsd' has a
    small fixed prologue; ParseRange handles those prologues explicitly. }
  Result := False;
  for i := Low(CONT) to High(CONT) do
    if CONT[i] = AType then Exit(True);
end;

{ 'meta' carries a 4-byte version/flags prologue before its children.
  'stsd' carries version/flags (4) + entry_count (4). }
function ContainerPrologue(const AType: string): Integer;
begin
  if AType = 'meta' then Result := 4
  else if AType = 'stsd' then Result := 8
  else Result := 0;
end;

{ ============================ TMP4Atom ============================== }

destructor TMP4Atom.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FChildren) do
    FChildren[i].Free;
  FChildren := nil;
  inherited Destroy;
end;

function TMP4Atom.ChildCount: Integer;
begin
  Result := Length(FChildren);
end;

function TMP4Atom.Child(AIndex: Integer): TMP4Atom;
begin
  if (AIndex < 0) or (AIndex > High(FChildren)) then
    Result := nil
  else
    Result := FChildren[AIndex];
end;

function TMP4Atom.Find(const AType: string): TMP4Atom;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to High(FChildren) do
    if FChildren[i].FKind.Equals(AType) then Exit(FChildren[i]);
end;

function TMP4Atom.FindAll(const AType: string): TMP4AtomList;
var
  i, n: Integer;
begin
  SetLength(Result, 0);
  n := 0;
  for i := 0 to High(FChildren) do
    if FChildren[i].FKind.Equals(AType) then
    begin
      SetLength(Result, n + 1);
      Result[n] := FChildren[i];
      Inc(n);
    end;
end;

function TMP4Atom.Path(const ASlashPath: string): TMP4Atom;
var
  parts: TArray<string>;
  i: Integer;
  cur: TMP4Atom;
begin
  parts := ASlashPath.Split(['/']);
  cur := Self;
  for i := 0 to High(parts) do
  begin
    if parts[i] = '' then Continue;
    cur := cur.Find(parts[i]);
    if cur = nil then Exit(nil);
  end;
  Result := cur;
end;

{ ============================ TMP4AtomTree ========================= }

constructor TMP4AtomTree.Create(const AData: TBytes);
begin
  inherited Create;
  FData := AData;
  if Length(FData) > MP4_MAX_FILE_BYTES then
    RaiseUDAWFmt(errInvalidArgument, MP4_SUBSYS,
      'MP4 buffer too large (%d bytes)', [Length(FData)]);
  FRoot := TMP4Atom.Create;
  FRoot.FKind := TFourCC.Make('ROOT');
  FRoot.FContentOffset := 0;
  FRoot.FContentSize := Length(FData);
  FAtomCount := 0;
  ParseRange(FRoot, 0, Length(FData), 0);
end;

destructor TMP4AtomTree.Destroy;
begin
  FRoot.Free;
  inherited Destroy;
end;

procedure TMP4AtomTree.ParseRange(AParent: TMP4Atom; AStart, AEnd: Int64;
  ADepth: Integer);
var
  pos, boxEnd: Int64;
  sz: Int64;
  hdr: Integer;
  fourcc: TFourCC;
  atom: TMP4Atom;
  prologue: Integer;
begin
  if ADepth >= MP4_MAX_DEPTH then Exit;
  pos := AStart;
  while pos + 8 <= AEnd do
  begin
    if FAtomCount >= MP4_MAX_ATOMS then Exit;

    sz := BE_U32(FData, pos);
    fourcc := ReadFourCC(FData, pos + 4);
    hdr := 8;

    if sz = 1 then
    begin
      if pos + 16 > AEnd then Break;
      sz := Int64(BE_U64(FData, pos + 8));
      hdr := 16;
    end
    else if sz = 0 then
      { "to end of file / enclosing box" }
      sz := AEnd - pos;

    atom := TMP4Atom.Create;
    atom.FKind := fourcc;
    atom.FHeaderOffset := pos;
    atom.FDeclaredSize := sz;

    if fourcc.Text = 'uuid' then
    begin
      if pos + hdr + 16 <= AEnd then
      begin
        SetLength(atom.FUserType, 16);
        Move(FData[pos + hdr], atom.FUserType[0], 16);
        Inc(hdr, 16);
      end;
    end;

    if sz < hdr then sz := hdr;                 // nonsense size -> just the header
    boxEnd := pos + sz;
    if boxEnd > AEnd then
    begin
      atom.FTruncated := True;
      boxEnd := AEnd;
    end;

    atom.FHeaderSize := hdr;
    atom.FContentOffset := pos + hdr;
    atom.FContentSize := boxEnd - atom.FContentOffset;
    if atom.FContentSize < 0 then atom.FContentSize := 0;

    SetLength(AParent.FChildren, Length(AParent.FChildren) + 1);
    AParent.FChildren[High(AParent.FChildren)] := atom;
    Inc(FAtomCount);

    if IsContainerBox(atom.FKind.Text) and (atom.FContentSize > 0) then
    begin
      prologue := ContainerPrologue(atom.FKind.Text);
      if atom.FContentSize > prologue then
        ParseRange(atom, atom.FContentOffset + prologue,
          atom.FContentOffset + atom.FContentSize, ADepth + 1);
      atom.FParsedChildren := True;
    end;

    if boxEnd <= pos then Break;               // no forward progress -> stop
    pos := boxEnd;
  end;
end;

function TMP4AtomTree.ContentBytes(AAtom: TMP4Atom): TBytes;
begin
  SetLength(Result, 0);
  if (AAtom = nil) or (AAtom.FContentSize <= 0) then Exit;
  if AAtom.FContentOffset + AAtom.FContentSize > Length(FData) then Exit;
  SetLength(Result, AAtom.FContentSize);
  Move(FData[AAtom.FContentOffset], Result[0], AAtom.FContentSize);
end;

function TMP4AtomTree.Describe: string;
var
  sb: TStringBuilder;

  procedure Walk(A: TMP4Atom; Indent: Integer);
  var
    i: Integer;
  begin
    for i := 0 to High(A.FChildren) do
    begin
      sb.Append(StringOfChar(' ', Indent * 2));
      sb.Append(A.FChildren[i].FKind.Text);
      sb.Append(Format(' (%d bytes at %d)',
        [A.FChildren[i].FDeclaredSize, A.FChildren[i].FHeaderOffset]));
      if A.FChildren[i].FTruncated then sb.Append(' [truncated]');
      sb.AppendLine;
      Walk(A.FChildren[i], Indent + 1);
    end;
  end;

begin
  sb := TStringBuilder.Create;
  try
    sb.Append(Format('MP4 atom tree - %d boxes, %d bytes', [FAtomCount, Length(FData)])).AppendLine;
    Walk(FRoot, 0);
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

{ ============================ TMP4BoxWriter ======================= }

constructor TMP4BoxWriter.Create;
begin
  inherited Create;
  FStream := TBytesStream.Create;
  FStackTop := 0;
end;

destructor TMP4BoxWriter.Destroy;
begin
  FStream.Free;
  inherited Destroy;
end;

procedure TMP4BoxWriter.U8(AValue: Byte);
begin
  FStream.WriteBuffer(AValue, 1);
end;

procedure TMP4BoxWriter.U16(AValue: Word);
var
  b: array[0..1] of Byte;
begin
  b[0] := (AValue shr 8) and $FF;
  b[1] := AValue and $FF;
  FStream.WriteBuffer(b[0], 2);
end;

procedure TMP4BoxWriter.U24(AValue: Cardinal);
var
  b: array[0..2] of Byte;
begin
  b[0] := (AValue shr 16) and $FF;
  b[1] := (AValue shr 8) and $FF;
  b[2] := AValue and $FF;
  FStream.WriteBuffer(b[0], 3);
end;

procedure TMP4BoxWriter.U32(AValue: Cardinal);
var
  b: array[0..3] of Byte;
begin
  b[0] := (AValue shr 24) and $FF;
  b[1] := (AValue shr 16) and $FF;
  b[2] := (AValue shr 8) and $FF;
  b[3] := AValue and $FF;
  FStream.WriteBuffer(b[0], 4);
end;

procedure TMP4BoxWriter.U64(AValue: UInt64);
begin
  U32(Cardinal((AValue shr 32) and $FFFFFFFF));
  U32(Cardinal(AValue and $FFFFFFFF));
end;

procedure TMP4BoxWriter.S16(AValue: SmallInt);
begin
  U16(Word(AValue));
end;

procedure TMP4BoxWriter.Fixed1616(AValue: Double);
begin
  U32(Cardinal(Round(AValue * 65536.0)));
end;

procedure TMP4BoxWriter.Fixed88(AValue: Double);
begin
  U16(Word(SmallInt(Round(AValue * 256.0))));
end;

procedure TMP4BoxWriter.FourCCStr(const AText: string);
var
  t: TFourCC;
  b: array[0..3] of Byte;
begin
  t := TFourCC.Make(AText);
  b[0] := (t.Value shr 24) and $FF;
  b[1] := (t.Value shr 16) and $FF;
  b[2] := (t.Value shr 8) and $FF;
  b[3] := t.Value and $FF;
  FStream.WriteBuffer(b[0], 4);
end;

procedure TMP4BoxWriter.RawBytes(const B: TBytes);
begin
  if Length(B) > 0 then
    FStream.WriteBuffer(B[0], Length(B));
end;

procedure TMP4BoxWriter.RawBytes(const B; ALen: Integer);
begin
  if ALen > 0 then
    FStream.WriteBuffer(B, ALen);
end;

procedure TMP4BoxWriter.Zeros(ACount: Integer);
var
  z: TBytes;
begin
  if ACount <= 0 then Exit;
  SetLength(z, ACount);
  FillChar(z[0], ACount, 0);
  FStream.WriteBuffer(z[0], ACount);
end;

procedure TMP4BoxWriter.AsciiZ(const AText: string);
var
  a: AnsiString;
begin
  a := AnsiString(AText);
  if Length(a) > 0 then
    FStream.WriteBuffer(a[1], Length(a));
end;

procedure TMP4BoxWriter.BeginBox(const AType: string);
begin
  if FStackTop >= Length(FStack) then
    SetLength(FStack, FStackTop + 8);
  FStack[FStackTop] := FStream.Position;
  Inc(FStackTop);
  U32(0);                 // size placeholder
  FourCCStr(AType);
end;

procedure TMP4BoxWriter.BeginFullBox(const AType: string; AVersion: Byte;
  AFlags: Cardinal);
begin
  BeginBox(AType);
  U8(AVersion);
  U24(AFlags and $FFFFFF);
end;

procedure TMP4BoxWriter.CloseBox;
var
  startAt, endAt, boxSize: Int64;
  sizeBytes: array[0..3] of Byte;
  saved: Int64;
begin
  if FStackTop <= 0 then
    RaiseUDAW(errInvalidState, MP4_SUBSYS, 'TMP4BoxWriter.CloseBox with no open box');
  Dec(FStackTop);
  startAt := FStack[FStackTop];
  endAt := FStream.Position;
  boxSize := endAt - startAt;
  if boxSize > $FFFFFFFF then
    RaiseUDAWFmt(errInvalidState, MP4_SUBSYS,
      'MP4 box exceeds 4 GiB (%d bytes) - 64-bit box writing not needed here', [boxSize]);
  sizeBytes[0] := (boxSize shr 24) and $FF;
  sizeBytes[1] := (boxSize shr 16) and $FF;
  sizeBytes[2] := (boxSize shr 8) and $FF;
  sizeBytes[3] := boxSize and $FF;
  saved := FStream.Position;
  FStream.Position := startAt;
  FStream.WriteBuffer(sizeBytes[0], 4);
  FStream.Position := saved;
end;

function TMP4BoxWriter.Position: Int64;
begin
  Result := FStream.Position;
end;

function TMP4BoxWriter.ToBytes: TBytes;
begin
  if FStackTop <> 0 then
    RaiseUDAWFmt(errInvalidState, MP4_SUBSYS,
      'TMP4BoxWriter.ToBytes with %d box(es) still open', [FStackTop]);
  SetLength(Result, FStream.Size);
  if FStream.Size > 0 then
    Move(FStream.Bytes[0], Result[0], FStream.Size);
end;

end.
