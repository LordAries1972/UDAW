unit UDAW.UI.ScorePdf;

{ Writes the Score (staff notation or guitar tablature) to a PDF file.

  The Score painter draws on a TGLCanvas; with this recorder attached to that canvas every line,
  filled rectangle, ellipse and piece of text it draws is captured as a vector operation instead
  of reaching the screen. The operations are then laid onto A4 landscape pages, whole systems
  (lines of music) per page, as PDF vector graphics with the standard Helvetica fonts. Music
  symbols that no standard font has (the clefs, the sharp sign) are carried as small bitmaps of the
  same glyphs the screen shows. The file is plain, uncompressed PDF 1.4 and needs nothing else. }

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, System.Math,
  System.Generics.Collections, Vcl.Graphics, UDAW.GL.Canvas, UDAW.UI.Score;

type
  TPdfOpKind = (pkLine, pkFill, pkOval, pkText);

  TPdfOp = record
    Kind: TPdfOpKind;
    X1, Y1, X2, Y2: Integer;       // a line's ends, or a box (X1, Y1, X2, Y2)
    Color, Color2: TColor;         // stroke / fill, or the text colour
    Width: Integer;
    Fill, Stroke: Boolean;
    Text: string;
    FontName: string;
    FontPx: Integer;
    Style: TFontStyles;
    CellH: Integer;                // the text's line height on screen
  end;

  TScorePdfRecorder = class(TGLRecorder)
  private
    FOps: TList<TPdfOp>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Line(X1, Y1, X2, Y2: Integer; AColor: TColor; AWidth: Integer); override;
    procedure Fill(const R: TRect; AColor: TColor); override;
    procedure Oval(const R: TRect; AFill: Boolean; AFillColor: TColor; AStroke: Boolean;
      AStrokeColor: TColor; AStrokeW: Integer); override;
    procedure Text(X, Y: Integer; const S, AFontName: string; AFontPx: Integer;
      AStyle: TFontStyles; AColor: TColor; ACellH: Integer); override;
    { lays the recorded operations onto pages and writes the PDF; returns the page count }
    function SaveToFile(const AFileName, ATitle: string; const ALayout: TScoreLayout;
      AViewWidth: Integer): Integer;
  end;

implementation

const
  PAGE_W = 842.0;     // A4 landscape, in points
  PAGE_H = 595.0;
  MARGIN = 30.0;
  HEADER_H = 18.0;

function Num(AValue: Double): string;
begin
  Result := FormatFloat('0.###', AValue, TFormatSettings.Invariant);
end;

function RgbOf(AColor: TColor): string;
var
  c: Integer;
begin
  c := ColorToRGB(AColor);
  Result := Num((c and $FF) / 255) + ' ' + Num(((c shr 8) and $FF) / 255) + ' ' + Num(((c shr 16) and $FF) / 255);
end;

function IsPaper(AColor: TColor): Boolean;
begin
  Result := (ColorToRGB(AColor) and $FFFFFF) = $FFFFFF;
end;

function PdfEscape(const S: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    case S[i] of
      '(', ')', '\': Result := Result + '\' + S[i];
    else
      Result := Result + S[i];
    end;
end;

function IsPlainText(const S: string): Boolean;
var
  i: Integer;
begin
  Result := True;
  for i := 1 to Length(S) do
    if (Ord(S[i]) < 32) or (Ord(S[i]) > 126) then Exit(False);
end;

{ ---------------- TScorePdfRecorder ---------------- }

constructor TScorePdfRecorder.Create;
begin
  inherited Create;
  FOps := TList<TPdfOp>.Create;
end;

destructor TScorePdfRecorder.Destroy;
begin
  FOps.Free;
  inherited Destroy;
end;

procedure TScorePdfRecorder.Line(X1, Y1, X2, Y2: Integer; AColor: TColor; AWidth: Integer);
var
  o: TPdfOp;
begin
  FillChar(o, SizeOf(o), 0);
  o.Kind := pkLine;
  o.X1 := X1; o.Y1 := Y1; o.X2 := X2; o.Y2 := Y2;
  o.Color := AColor;
  o.Width := AWidth;
  FOps.Add(o);
end;

procedure TScorePdfRecorder.Fill(const R: TRect; AColor: TColor);
var
  o: TPdfOp;
begin
  FillChar(o, SizeOf(o), 0);
  o.Kind := pkFill;
  o.X1 := R.Left; o.Y1 := R.Top; o.X2 := R.Right; o.Y2 := R.Bottom;
  o.Color2 := AColor;
  FOps.Add(o);
end;

procedure TScorePdfRecorder.Oval(const R: TRect; AFill: Boolean; AFillColor: TColor; AStroke: Boolean;
  AStrokeColor: TColor; AStrokeW: Integer);
var
  o: TPdfOp;
begin
  FillChar(o, SizeOf(o), 0);
  o.Kind := pkOval;
  o.X1 := R.Left; o.Y1 := R.Top; o.X2 := R.Right; o.Y2 := R.Bottom;
  o.Fill := AFill;
  o.Stroke := AStroke;
  o.Color2 := AFillColor;
  o.Color := AStrokeColor;
  o.Width := AStrokeW;
  FOps.Add(o);
end;

procedure TScorePdfRecorder.Text(X, Y: Integer; const S, AFontName: string; AFontPx: Integer;
  AStyle: TFontStyles; AColor: TColor; ACellH: Integer);
var
  o: TPdfOp;
begin
  if S = '' then Exit;
  FillChar(o, SizeOf(o), 0);
  o.Kind := pkText;
  o.X1 := X; o.Y1 := Y;
  o.Text := S;
  o.FontName := AFontName;
  o.FontPx := AFontPx;
  o.Style := AStyle;
  o.Color := AColor;
  o.CellH := ACellH;
  FOps.Add(o);
end;

function TScorePdfRecorder.SaveToFile(const AFileName, ATitle: string; const ALayout: TScoreLayout;
  AViewWidth: Integer): Integer;
var
  sc, availH: Double;
  perPage, pageCount, i, k, pg, imgCount: Integer;
  pages: TArray<TStringBuilder>;
  pageImgs: TArray<TList<Integer>>;
  imgObjs: TList<string>;        // the PDF object body of every glyph mask
  imgKeys: TDictionary<string, Integer>;
  o: TPdfOp;
  y0, refY: Integer;
  sb: TStringBuilder;
  offsets: TList<Integer>;
  title: string;
  out_: TStringBuilder;
  objNo, contentNo, pageNo, firstPage: Integer;
  kids: string;
  bytes: TBytes;
  fs: TFileStream;

  function PX(AX: Double): Double;
  begin
    Result := MARGIN + AX * sc;
  end;

  function PY(AY: Double; APageY0: Integer): Double;
  begin
    Result := PAGE_H - MARGIN - HEADER_H - (AY - APageY0) * sc;
  end;

  { the index of a bitmap of one glyph run, made on first use }
  function GlyphImage(const AOp: TPdfOp; out AW, AH: Integer): Integer;
  const
    SCALE = 4;
  var
    key: string;
    bmp: TBitmap;
    x, y, rowBytes, b: Integer;
    row: PByteArray;
    hex: TStringBuilder;
    bits: Byte;
  begin
    key := AOp.FontName + '|' + IntToStr(AOp.FontPx) + '|' + IntToStr(Byte(AOp.Style)) + '|' + AOp.Text;
    bmp := TBitmap.Create;
    try
      bmp.PixelFormat := pf24bit;
      bmp.Canvas.Font.Name := AOp.FontName;
      bmp.Canvas.Font.Height := -AOp.FontPx * SCALE;
      bmp.Canvas.Font.Style := AOp.Style;
      bmp.Canvas.Font.Color := clBlack;
      AW := bmp.Canvas.TextWidth(AOp.Text) + 2 * SCALE;
      AH := bmp.Canvas.TextHeight(AOp.Text);
      bmp.SetSize(AW, AH);
      bmp.Canvas.Brush.Color := clWhite;
      bmp.Canvas.FillRect(Rect(0, 0, AW, AH));
      bmp.Canvas.Brush.Style := bsClear;
      bmp.Canvas.Font.Name := AOp.FontName;
      bmp.Canvas.Font.Height := -AOp.FontPx * SCALE;
      bmp.Canvas.Font.Style := AOp.Style;
      bmp.Canvas.Font.Color := clBlack;
      bmp.Canvas.TextOut(0, 0, AOp.Text);
      if imgKeys.TryGetValue(key, Result) then Exit;
      rowBytes := (AW + 7) div 8;
      hex := TStringBuilder.Create;
      try
        for y := 0 to AH - 1 do
        begin
          row := bmp.ScanLine[y];
          for b := 0 to rowBytes - 1 do
          begin
            bits := $FF;
            for x := 0 to 7 do
              if b * 8 + x < AW then
                if row^[(b * 8 + x) * 3 + 1] < 128 then bits := bits and not (Byte($80) shr x);
            hex.Append(IntToHex(bits, 2));
          end;
        end;
        hex.Append('>');
        Result := imgObjs.Count;
        imgObjs.Add(Format('<< /Type /XObject /Subtype /Image /Width %d /Height %d /ImageMask true ' +
          '/BitsPerComponent 1 /Filter /ASCIIHexDecode /Length %d >>', [AW, AH, hex.Length]) + #10'stream'#10 +
          hex.ToString + #10'endstream');
        imgKeys.Add(key, Result);
      finally
        hex.Free;
      end;
    finally
      bmp.Free;
    end;
  end;

  procedure EmitOp(APage: Integer; const AOp: TPdfOp);
  var
    sbp: TStringBuilder;
    x1, y2, w, h, cx, cy, rx, ry, kx, ky, base: Double;
    fontId: string;
    gi, gw, gh: Integer;
  begin
    sbp := pages[APage];
    y0 := ALayout.TopPad + APage * perPage * ALayout.SystemH;
    case AOp.Kind of
      pkLine:
        begin
          if IsPaper(AOp.Color) then Exit;
          sbp.Append(RgbOf(AOp.Color)).Append(' RG ').Append(Num(Max(1, AOp.Width) * sc)).Append(' w ')
            .Append(Num(PX(AOp.X1 + 0.5))).Append(' ').Append(Num(PY(AOp.Y1 + 0.5, y0))).Append(' m ')
            .Append(Num(PX(AOp.X2 + 0.5))).Append(' ').Append(Num(PY(AOp.Y2 + 0.5, y0))).Append(' l S'#10);
        end;
      pkFill:
        begin
          if IsPaper(AOp.Color2) then Exit;
          x1 := PX(AOp.X1);
          y2 := PY(AOp.Y2, y0);
          sbp.Append(RgbOf(AOp.Color2)).Append(' rg ').Append(Num(x1)).Append(' ').Append(Num(y2)).Append(' ')
            .Append(Num((AOp.X2 - AOp.X1) * sc)).Append(' ').Append(Num((AOp.Y2 - AOp.Y1) * sc)).Append(' re f'#10);
        end;
      pkOval:
        begin
          cx := PX((AOp.X1 + AOp.X2) / 2);
          cy := PY((AOp.Y1 + AOp.Y2) / 2, y0);
          rx := (AOp.X2 - AOp.X1) / 2 * sc;
          ry := (AOp.Y2 - AOp.Y1) / 2 * sc;
          kx := rx * 0.5523;
          ky := ry * 0.5523;
          if not (AOp.Fill or AOp.Stroke) then Exit;
          if AOp.Fill and not IsPaper(AOp.Color2) then sbp.Append(RgbOf(AOp.Color2)).Append(' rg ');
          if AOp.Stroke then sbp.Append(RgbOf(AOp.Color)).Append(' RG ').Append(Num(Max(1, AOp.Width) * sc)).Append(' w ');
          sbp.Append(Num(cx + rx)).Append(' ').Append(Num(cy)).Append(' m ')
            .Append(Num(cx + rx)).Append(' ').Append(Num(cy + ky)).Append(' ').Append(Num(cx + kx)).Append(' ').Append(Num(cy + ry)).Append(' ').Append(Num(cx)).Append(' ').Append(Num(cy + ry)).Append(' c ')
            .Append(Num(cx - kx)).Append(' ').Append(Num(cy + ry)).Append(' ').Append(Num(cx - rx)).Append(' ').Append(Num(cy + ky)).Append(' ').Append(Num(cx - rx)).Append(' ').Append(Num(cy)).Append(' c ')
            .Append(Num(cx - rx)).Append(' ').Append(Num(cy - ky)).Append(' ').Append(Num(cx - kx)).Append(' ').Append(Num(cy - ry)).Append(' ').Append(Num(cx)).Append(' ').Append(Num(cy - ry)).Append(' c ')
            .Append(Num(cx + kx)).Append(' ').Append(Num(cy - ry)).Append(' ').Append(Num(cx + rx)).Append(' ').Append(Num(cy - ky)).Append(' ').Append(Num(cx + rx)).Append(' ').Append(Num(cy)).Append(' c ');
          if AOp.Fill and AOp.Stroke then sbp.Append('B'#10)
          else if AOp.Fill then sbp.Append('f'#10)
          else sbp.Append('S'#10);
        end;
      pkText:
        begin
          if IsPaper(AOp.Color) then Exit;
          if IsPlainText(AOp.Text) then
          begin
            if fsBold in AOp.Style then fontId := '/F2' else fontId := '/F1';
            base := PY(AOp.Y1 + AOp.CellH * 0.8, y0);
            sbp.Append(RgbOf(AOp.Color)).Append(' rg BT ').Append(fontId).Append(' ')
              .Append(Num(AOp.FontPx * sc * 0.95)).Append(' Tf ').Append(Num(PX(AOp.X1))).Append(' ')
              .Append(Num(base)).Append(' Td (').Append(PdfEscape(AOp.Text)).Append(') Tj ET'#10);
          end
          else
          begin
            gi := GlyphImage(AOp, gw, gh);
            if not pageImgs[APage].Contains(gi) then pageImgs[APage].Add(gi);
            w := gw / 4 * sc;
            h := gh / 4 * sc;
            sbp.Append(RgbOf(AOp.Color)).Append(' rg q ').Append(Num(w)).Append(' 0 0 ').Append(Num(h)).Append(' ')
              .Append(Num(PX(AOp.X1))).Append(' ').Append(Num(PY(AOp.Y1 + gh / 4, y0)))
              .Append(' cm /Im').Append(IntToStr(gi)).Append(' Do Q'#10);
          end;
        end;
    end;
  end;

begin
  { the header text goes into the file as plain ASCII }
  title := ATitle;
  for i := 1 to Length(title) do
    if (Ord(title[i]) < 32) or (Ord(title[i]) > 126) then title[i] := '?';
  { the whole width of one laid-out line fits the page width }
  sc := (PAGE_W - 2 * MARGIN) / Max(1, AViewWidth);
  availH := (PAGE_H - 2 * MARGIN - HEADER_H) / sc;
  perPage := Max(1, Trunc((availH - ALayout.TopPad) / Max(1, ALayout.SystemH)));
  k := Max(1, (ALayout.ContentH - 40 - ALayout.TopPad) div Max(1, ALayout.SystemH));
  pageCount := Max(1, (k + perPage - 1) div perPage);
  SetLength(pages, pageCount);
  SetLength(pageImgs, pageCount);
  imgObjs := TList<string>.Create;
  imgKeys := TDictionary<string, Integer>.Create;
  try
    for i := 0 to pageCount - 1 do
    begin
      pages[i] := TStringBuilder.Create;
      pageImgs[i] := TList<Integer>.Create;
    end;
    try
      for i := 0 to FOps.Count - 1 do
      begin
        o := FOps[i];
        case o.Kind of
          pkLine: refY := Min(o.Y1, o.Y2);
        else
          refY := o.Y1;
        end;
        k := Max(0, (refY - ALayout.TopPad) div Max(1, ALayout.SystemH));
        pg := Min(pageCount - 1, k div perPage);
        EmitOp(pg, o);
      end;

      { ---- the file: catalog, pages, fonts, then per page its content and the glyph images ---- }
      offsets := TList<Integer>.Create;
      out_ := TStringBuilder.Create;
      try
        out_.Append('%PDF-1.4'#10);
        { 1 catalog, 2 pages, 3/4 fonts, 5.. glyph images, then content + page per page }
        imgCount := imgObjs.Count;
        firstPage := 5 + imgCount;
        offsets.Add(0);
        offsets.Add(out_.Length);
        out_.Append('1 0 obj'#10'<< /Type /Catalog /Pages 2 0 R >>'#10'endobj'#10);
        kids := '';
        for i := 0 to pageCount - 1 do
          kids := kids + IntToStr(firstPage + i * 2 + 1) + ' 0 R ';
        offsets.Add(out_.Length);
        out_.Append('2 0 obj'#10'<< /Type /Pages /Kids [').Append(kids).Append('] /Count ')
          .Append(IntToStr(pageCount)).Append(' >>'#10'endobj'#10);
        offsets.Add(out_.Length);
        out_.Append('3 0 obj'#10'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>'#10'endobj'#10);
        offsets.Add(out_.Length);
        out_.Append('4 0 obj'#10'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>'#10'endobj'#10);
        for i := 0 to imgCount - 1 do
        begin
          offsets.Add(out_.Length);
          out_.Append(IntToStr(5 + i)).Append(' 0 obj'#10).Append(imgObjs[i]).Append(#10'endobj'#10);
        end;
        for i := 0 to pageCount - 1 do
        begin
          contentNo := firstPage + i * 2;
          pageNo := contentNo + 1;
          sb := TStringBuilder.Create;
          try
            { the header: title and page number, in the top margin }
            sb.Append('0.35 g BT /F1 9 Tf ').Append(Num(MARGIN)).Append(' ')
              .Append(Num(PAGE_H - MARGIN + 4)).Append(' Td (').Append(PdfEscape(title)).Append(') Tj ET'#10);
            sb.Append('BT /F1 9 Tf ').Append(Num(PAGE_W - MARGIN - 60)).Append(' ')
              .Append(Num(PAGE_H - MARGIN + 4)).Append(' Td (Page ').Append(IntToStr(i + 1)).Append(' of ')
              .Append(IntToStr(pageCount)).Append(') Tj ET'#10);
            sb.Append(pages[i].ToString);
            offsets.Add(out_.Length);
            out_.Append(IntToStr(contentNo)).Append(' 0 obj'#10'<< /Length ').Append(IntToStr(sb.Length))
              .Append(' >>'#10'stream'#10).Append(sb.ToString).Append('endstream'#10'endobj'#10);
          finally
            sb.Free;
          end;
          offsets.Add(out_.Length);
          out_.Append(IntToStr(pageNo)).Append(' 0 obj'#10'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ')
            .Append(Num(PAGE_W)).Append(' ').Append(Num(PAGE_H)).Append('] /Contents ')
            .Append(IntToStr(contentNo)).Append(' 0 R /Resources << /Font << /F1 3 0 R /F2 4 0 R >>');
          if pageImgs[i].Count > 0 then
          begin
            out_.Append(' /XObject <<');
            for k := 0 to pageImgs[i].Count - 1 do
              out_.Append(' /Im').Append(IntToStr(pageImgs[i][k])).Append(' ').Append(IntToStr(5 + pageImgs[i][k])).Append(' 0 R');
            out_.Append(' >>');
          end;
          out_.Append(' >> >>'#10'endobj'#10);
        end;
        objNo := offsets.Count;
        k := out_.Length;
        out_.Append('xref'#10'0 ').Append(IntToStr(objNo)).Append(#10'0000000000 65535 f '#10);
        for i := 1 to objNo - 1 do
          out_.Append(Format('%.10d 00000 n '#10, [offsets[i]]));
        out_.Append('trailer'#10'<< /Size ').Append(IntToStr(objNo)).Append(' /Root 1 0 R >>'#10'startxref'#10)
          .Append(IntToStr(k)).Append(#10'%%EOF'#10);
        { the file is plain 7-bit text throughout, so characters are bytes }
        SetLength(bytes, out_.Length);
        for i := 0 to out_.Length - 1 do
          bytes[i] := Byte(Ord(out_.Chars[i]) and $FF);
        fs := TFileStream.Create(AFileName, fmCreate);
        try
          if Length(bytes) > 0 then fs.WriteBuffer(bytes[0], Length(bytes));
        finally
          fs.Free;
        end;
        Result := pageCount;
      finally
        out_.Free;
        offsets.Free;
      end;
    finally
      for i := 0 to pageCount - 1 do
      begin
        pages[i].Free;
        pageImgs[i].Free;
      end;
    end;
  finally
    imgKeys.Free;
    imgObjs.Free;
  end;
end;

end.
