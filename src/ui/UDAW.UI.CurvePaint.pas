unit UDAW.UI.CurvePaint;
{$I udaw.inc}

{ Draws the response of one effect on a GL canvas: an EQ / filter's gain against frequency, or a
  dynamics effect's input-to-output transfer curve. Shared by the mixer insert dialog and the
  effect editor. }

interface

uses
  Graphics, UDAW.GL.Canvas;

{ Fills the whole w x h area. AKindId is the effect kind id, AParams its "key=value;..." settings. }
procedure PaintEffectCurve(cv: TGLCanvas; w, h: Integer; const AKindId, AParams: string);

implementation

uses UDAW.DSP.MathTables,
  SysUtils, Math, Types, Vcl.Themes, UDAW.DSP.CurveMath;

{ the colours come from the active visual theme }
function ThemeCol(AColor: TColor): TColor;
begin
  Result := ColorToRGB(StyleServices.GetSystemColor(AColor));
end;

function MixCol(A, B: TColor; T: Double): TColor;
var
  ca, cb: LongInt;
begin
  ca := ColorToRGB(A);
  cb := ColorToRGB(B);
  Result := TColor(
    Byte(Round((ca and $FF) + ((cb and $FF) - (ca and $FF)) * T)) or
    (Byte(Round(((ca shr 8) and $FF) + (((cb shr 8) and $FF) - ((ca shr 8) and $FF)) * T)) shl 8) or
    (Byte(Round(((ca shr 16) and $FF) + (((cb shr 16) and $FF) - ((ca shr 16) and $FF)) * T)) shl 16));
end;

procedure PaintEffectCurve(cv: TGLCanvas; w, h: Integer; const AKindId, AParams: string);
const
  FMIN = 20.0;
  FMAX = 20000.0;
var
  i, x, y: Integer;
  lbl: string;
  kind: TCurveKind;
  f, v, lo, hi, db: Double;
  first: Boolean;
  bg, ink, grid, muted, accent: TColor;

  function XOfFreq(AF: Double): Integer;
  begin
    Result := Round(FastLn(AF / FMIN) / FastLn(FMAX / FMIN) * (w - 1));
  end;

  function YOfDb(ADb: Double): Integer;
  begin
    if ADb < lo then ADb := lo else if ADb > hi then ADb := hi;
    Result := Round((hi - ADb) / (hi - lo) * (h - 1));
  end;

begin
  bg := ThemeCol(clWindow);
  ink := ThemeCol(clWindowText);
  grid := MixCol(bg, ink, 0.18);
  muted := MixCol(bg, ink, 0.6);
  accent := MixCol(ThemeCol(clHighlight), ink, 0.2);
  cv.Brush.Color := bg;
  cv.Brush.Style := bsSolid;
  cv.FillRect(Rect(0, 0, w, h));
  kind := CurveKindFor(AKindId);
  if kind = ckNone then
  begin
    cv.Font.Color := muted;
    cv.TextOut(8, 8, 'No curve display for this effect.');
    Exit;
  end;
  cv.Font.Size := 7;
  cv.Pen.Style := psSolid;
  if kind = ckFrequency then
  begin
    lo := -24;
    hi := 24;
    { grid: every 12 dB and each decade of frequency }
    cv.Pen.Color := grid;
    db := lo;
    while db <= hi do
    begin
      y := YOfDb(db);
      cv.MoveTo(0, y);
      cv.LineTo(w, y);
      cv.Font.Color := muted;
      cv.TextOut(2, y - 5, Format('%+.0f dB', [db]));
      db := db + 12;
    end;
    for i := 0 to 3 do
    begin
      f := 100 * FastExp10(i - 1);
      if (f < FMIN) or (f > FMAX) then Continue;
      x := XOfFreq(f);
      cv.MoveTo(x, 0);
      cv.LineTo(x, h);
      if f >= 1000 then lbl := Format('%.0f kHz', [f / 1000]) else lbl := Format('%.0f Hz', [f]);
      cv.TextOut(x + 2, h - 12, lbl);
    end;
    cv.Pen.Color := accent;
    cv.Pen.Width := 2;
    first := True;
    for x := 0 to w - 1 do
    begin
      f := FMIN * FastPow(FMAX / FMIN, x / Max(1, w - 1));
      y := YOfDb(EqResponseDb(AKindId, AParams, f));
      if first then
      begin
        cv.MoveTo(x, y);
        first := False;
      end
      else
        cv.LineTo(x, y);
    end;
  end
  else
  begin
    lo := -60;
    hi := 6;
    cv.Pen.Color := grid;
    db := -60;
    while db <= 0 do
    begin
      x := Round((db - lo) / (hi - lo) * (w - 1));
      y := YOfDb(db);
      cv.MoveTo(x, 0);
      cv.LineTo(x, h);
      cv.MoveTo(0, y);
      cv.LineTo(w, y);
      cv.Font.Color := muted;
      cv.TextOut(x + 2, h - 12, Format('%.0f', [db]));
      db := db + 20;
    end;
    { unity line, then the transfer curve }
    cv.Pen.Color := muted;
    cv.Pen.Style := psDot;
    cv.MoveTo(0, YOfDb(lo));
    cv.LineTo(w - 1, YOfDb(hi));
    cv.Pen.Style := psSolid;
    cv.Pen.Color := accent;
    cv.Pen.Width := 2;
    for x := 0 to w - 1 do
    begin
      v := lo + x / Max(1, w - 1) * (hi - lo);
      y := YOfDb(TransferOutDb(AKindId, AParams, v));
      if x = 0 then
        cv.MoveTo(x, y)
      else
        cv.LineTo(x, y);
    end;
    cv.Font.Color := muted;
    cv.TextOut(w - 90, 2, 'input dB -> output dB');
  end;
  cv.Pen.Width := 1;
end;

end.
