unit UDAW.AI.MusicTab;
{$I udaw.inc}

{ "Music Tabular Only" - text-only tablature/notation generation.

  Luma's API has no music service, so this mode never calls Luma: the AI tab
  sends the prompt to a text provider (Claude/OpenAI/DeepSeek, on the user's
  own key) using MusicTabSystemPrompt, and this unit turns the fixed-width
  reply into a study-ready PDF saved under <Recordings>\AI\Rendered.

  The PDF writer is from scratch (PDF 1.4, base-14 Courier, WinAnsi) in keeping
  with the no-third-party rule. Courier is monospaced, so tab columns stay
  aligned exactly as the model wrote them. }

interface

uses
  SysUtils, Classes;

function MusicTabSystemPrompt: string;

{ <ARecordingsRoot>\AI\Rendered, created if missing. }
function MusicTabRenderedFolder(const ARecordingsRoot: string): string;

{ Filesystem-safe, length-limited file stem derived from the prompt. }
function MusicTabFileStem(const APrompt: string): string;

{ Drops markdown code-fence lines the model may wrap around the tab. }
function MusicTabStripFences(const AText: string): string;

{ Whole PDF file as a string whose every char is one byte (Latin-1). }
function BuildTextPdf(const ATitle, ASubtitle, ABody: string): string;

{ Renders ATabText to a uniquely named PDF in the Rendered folder; returns the
  full path. Raises on an empty tab or a file error. }
function MusicTabToPdf(const ARecordingsRoot, APrompt, ATabText: string): string;

implementation

const
  PAGE_W = 595;          // A4 in points
  PAGE_H = 842;
  MARGIN = 40;
  BODY_SIZE = 9;
  LEADING = 11;
  MAX_COLS = 95;         // Courier 9pt = 5.4pt/char across (595 - 80) pt
  FIRST_PAGE_TOP = 760;  // below title + subtitle
  OTHER_PAGE_TOP = 802;
  BOTTOM_LIMIT = 50;

function MusicTabSystemPrompt: string;
begin
  Result :=
    'You are a music teacher writing practice material. Reply with plain text only, ' +
    'laid out for a MONOSPACED font, no markdown, no code fences, no commentary before or ' +
    'after. Start with a short header (title, key, tempo, time signature, tuning or ' +
    'instrument). Then write the music as tablature: one 6-line staff per guitar phrase ' +
    '(strings e B G D A E, fret numbers on lines, bar lines "|"), or 4 lines for bass, ' +
    'or a drum grid (one row per drum, "x" or "o" hits on a 16th-note grid). Keep every ' +
    'line at most 90 characters wide so nothing wraps, label sections (Intro, Verse, ...) ' +
    'and bar numbers, and add one or two practice tips at the end. Chord charts may be ' +
    'shown as chord names above the tab.';
end;

function MusicTabRenderedFolder(const ARecordingsRoot: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ARecordingsRoot) + 'AI' + PathDelim + 'Rendered';
  ForceDirectories(Result);
end;

function MusicTabFileStem(const APrompt: string): string;
var
  i: Integer;
  c: Char;
begin
  Result := '';
  for i := 1 to Length(APrompt) do
  begin
    c := APrompt[i];
    if CharInSet(c, ['A'..'Z', 'a'..'z', '0'..'9']) then
      Result := Result + c
    else if (c = ' ') or (c = '-') or (c = '_') then
    begin
      if (Result <> '') and (Result[Length(Result)] <> '_') then
        Result := Result + '_';
    end;
    if Length(Result) >= 40 then Break;
  end;
  while (Result <> '') and (Result[Length(Result)] = '_') do
    SetLength(Result, Length(Result) - 1);
  if Result = '' then Result := 'music_tab';
end;

function MusicTabStripFences(const AText: string): string;
var
  sl: TStringList;
  i: Integer;
begin
  sl := TStringList.Create;
  try
    sl.Text := AText;
    for i := sl.Count - 1 downto 0 do
      if Copy(TrimLeft(sl[i]), 1, 3) = '```' then
        sl.Delete(i);
    Result := sl.Text;
  finally
    sl.Free;
  end;
end;

{ One byte per char: control -> space, anything outside Latin-1 -> '?'; then
  escape the three characters that are special inside a PDF string. }
function PdfEscape(const S: string): string;
var
  i: Integer;
  c: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if Ord(c) < 32 then c := ' '
    else if Ord(c) > 255 then c := '?';
    if (c = '\') or (c = '(') or (c = ')') then
      Result := Result + '\' + c
    else
      Result := Result + c;
  end;
end;

function BuildTextPdf(const ATitle, ASubtitle, ABody: string): string;
var
  src, lines: TStringList;
  sb: TStringBuilder;
  offsets: array of Integer;
  i, pageCount, pos, capacity, y, pageIdx, n, xrefAt, objCount: Integer;
  ln, kids, content: string;

  procedure BeginObj(AId: Integer);
  begin
    offsets[AId] := sb.Length;
    sb.Append(IntToStr(AId)).Append(' 0 obj').Append(#10);
  end;

  procedure EndObj;
  begin
    sb.Append('endobj').Append(#10);
  end;

begin
  { split into display lines, hard-wrapping anything wider than the page }
  src := TStringList.Create;
  lines := TStringList.Create;
  try
    src.Text := StringReplace(ABody, #9, '    ', [rfReplaceAll]);
    for i := 0 to src.Count - 1 do
    begin
      ln := TrimRight(src[i]);
      if ln = '' then lines.Add('')
      else
        while ln <> '' do
        begin
          lines.Add(Copy(ln, 1, MAX_COLS));
          Delete(ln, 1, MAX_COLS);
        end;
    end;

    { paginate }
    pageCount := 1;
    pos := 0;
    capacity := (FIRST_PAGE_TOP - BOTTOM_LIMIT) div LEADING;
    while pos + capacity < lines.Count do
    begin
      Inc(pos, capacity);
      Inc(pageCount);
      capacity := (OTHER_PAGE_TOP - BOTTOM_LIMIT) div LEADING;
    end;

    objCount := 4 + 2 * pageCount;          // 1 catalog, 2 pages, 3/4 fonts, then page+content pairs
    SetLength(offsets, objCount + 1);
    sb := TStringBuilder.Create;
    try
      sb.Append('%PDF-1.4').Append(#10).Append('%').Append(#$E2#$E3#$CF#$D3).Append(#10);

      BeginObj(1);
      sb.Append('<< /Type /Catalog /Pages 2 0 R >>').Append(#10);
      EndObj;

      kids := '';
      for i := 0 to pageCount - 1 do
        kids := kids + IntToStr(5 + 2 * i) + ' 0 R ';
      BeginObj(2);
      sb.Append('<< /Type /Pages /Kids [ ' + kids + '] /Count ' + IntToStr(pageCount) + ' >>').Append(#10);
      EndObj;

      BeginObj(3);
      sb.Append('<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>').Append(#10);
      EndObj;
      BeginObj(4);
      sb.Append('<< /Type /Font /Subtype /Type1 /BaseFont /Courier-Bold /Encoding /WinAnsiEncoding >>').Append(#10);
      EndObj;

      pos := 0;
      for pageIdx := 0 to pageCount - 1 do
      begin
        if pageIdx = 0 then
        begin
          y := FIRST_PAGE_TOP;
          capacity := (FIRST_PAGE_TOP - BOTTOM_LIMIT) div LEADING;
        end
        else
        begin
          y := OTHER_PAGE_TOP;
          capacity := (OTHER_PAGE_TOP - BOTTOM_LIMIT) div LEADING;
        end;

        content := '';
        if pageIdx = 0 then
        begin
          content := content + 'BT /F2 16 Tf ' + IntToStr(MARGIN) + ' 800 Td (' + PdfEscape(Copy(ATitle, 1, 60)) + ') Tj ET' + #10;
          content := content + 'BT /F1 8 Tf ' + IntToStr(MARGIN) + ' 784 Td (' + PdfEscape(Copy(ASubtitle, 1, 105)) + ') Tj ET' + #10;
        end;
        content := content + 'BT /F1 ' + IntToStr(BODY_SIZE) + ' Tf ' + IntToStr(LEADING) + ' TL ' +
          IntToStr(MARGIN) + ' ' + IntToStr(y) + ' Td' + #10;
        n := 0;
        while (n < capacity) and (pos < lines.Count) do
        begin
          if lines[pos] <> '' then
            content := content + '(' + PdfEscape(lines[pos]) + ') Tj';
          content := content + ' T*' + #10;
          Inc(pos);
          Inc(n);
        end;
        content := content + 'ET' + #10;
        content := content + 'BT /F1 8 Tf ' + IntToStr(MARGIN) + ' 24 Td (Page ' + IntToStr(pageIdx + 1) +
          ' of ' + IntToStr(pageCount) + ') Tj ET' + #10;

        BeginObj(5 + 2 * pageIdx);
        sb.Append('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ' + IntToStr(PAGE_W) + ' ' + IntToStr(PAGE_H) +
          '] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents ' + IntToStr(6 + 2 * pageIdx) + ' 0 R >>').Append(#10);
        EndObj;
        BeginObj(6 + 2 * pageIdx);
        sb.Append('<< /Length ' + IntToStr(Length(content)) + ' >>').Append(#10);
        sb.Append('stream').Append(#10).Append(content).Append('endstream').Append(#10);
        EndObj;
      end;

      xrefAt := sb.Length;
      sb.Append('xref').Append(#10).Append('0 ' + IntToStr(objCount + 1)).Append(#10);
      sb.Append('0000000000 65535 f ').Append(#10);
      for i := 1 to objCount do
        sb.Append(Format('%.10d 00000 n ', [offsets[i]])).Append(#10);
      sb.Append('trailer').Append(#10);
      sb.Append('<< /Size ' + IntToStr(objCount + 1) + ' /Root 1 0 R >>').Append(#10);
      sb.Append('startxref').Append(#10).Append(IntToStr(xrefAt)).Append(#10).Append('%%EOF').Append(#10);
      Result := sb.ToString;
    finally
      sb.Free;
    end;
  finally
    lines.Free;
    src.Free;
  end;
end;

function MusicTabToPdf(const ARecordingsRoot, APrompt, ATabText: string): string;
var
  folder, body, pdf: string;
  bytes: TBytes;
  fs: TFileStream;
  i: Integer;
begin
  body := MusicTabStripFences(ATabText);
  if Trim(body) = '' then
    raise Exception.Create('the AI/SI returned no tablature to render');
  folder := MusicTabRenderedFolder(ARecordingsRoot);
  Result := folder + PathDelim + MusicTabFileStem(APrompt) + '_' +
    FormatDateTime('yyyymmdd_hhnnss', Now) + '.pdf';

  pdf := BuildTextPdf('Music Practice Sheet', 'Prompt: ' + StringReplace(APrompt, #13#10, ' ', [rfReplaceAll]) +
    '  -  generated ' + FormatDateTime('yyyy-mm-dd hh:nn', Now) + ' by UDAW', body);
  SetLength(bytes, Length(pdf));
  for i := 1 to Length(pdf) do
    bytes[i - 1] := Byte(Ord(pdf[i]) and $FF);
  fs := TFileStream.Create(Result, fmCreate);
  try
    fs.WriteBuffer(bytes[0], Length(bytes));
  finally
    fs.Free;
  end;
end;

end.
