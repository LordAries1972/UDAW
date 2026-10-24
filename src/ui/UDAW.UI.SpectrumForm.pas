unit UDAW.UI.SpectrumForm;
{$I udaw.inc}

{ The Timeline's master spectrum in a window of its own: opened by double-clicking the small
  spectrum in the Timeline's top-left corner. A resizable, 3D-styled analyser - log-frequency
  bars built from lit blocks with a top and a side face, peak-hold caps, a back wall with a dB /
  frequency grid, a glossy floor reflection and a peak read-out. The main form only hands it the
  latest spectrum (Feed); smoothing, falling bars and peak hold are done here on the window's own
  animation timer, so it keeps moving smoothly between the main form's refreshes. Every control
  is placed at design time; only the picture is painted at run time. }

interface

uses
  Winapi.Windows, System.Types, SysUtils, Classes, Math, Graphics, Controls, Forms, ExtCtrls,
  UDAW.GL.Canvas;

type
  TfrmSpectrum = class(TForm)
    pbView: TGLView;
    tmrAnim: TTimer;
    procedure pbViewPaint(Sender: TObject);
    procedure tmrAnimTimer(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure FormHide(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
  private
    FDb: TArray<Double>;          // latest one-sided spectrum, dBFS per bin
    FRate: Integer;
    FActive: Boolean;
    FLevel: TArray<Double>;       // per band: the bar's current height, dB
    FPeak: TArray<Double>;        // per band: the peak-hold cap, dB
    FHold: TArray<Integer>;       // per band: frames left before the cap starts to fall
    FPeakDb: Double;              // loudest band right now
    FPeakHz: Double;
    function BandCount: Integer;
    function BandEdgeHz(AIndex, ACount: Integer): Double;
    procedure Analyse;
  public
    { the newest spectrum from the main form's refresh; AActive False while nothing is playing }
    procedure Feed(const ADb: array of Double; ARate: Integer; AActive: Boolean);
  end;

implementation


uses
  UDAW.DSP.MathTables;

{$R *.dfm}

const
  MIN_HZ = 30.0;
  MAX_HZ = 20000.0;
  TOP_DB = 0.0;
  BOT_DB = -90.0;
  FALL_DB = 1.6;          // bar fall per animation frame
  PEAK_FALL_DB = 0.7;
  HOLD_FRAMES = 36;
  MARGIN_L = 58;
  MARGIN_R = 30;
  MARGIN_T = 62;
  MARGIN_B = 92;
  GRID_HZ: array[0..8] of Double = (50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000);

function Shade(AColor: TColor; AFactor: Double): TColor;
var
  c: Integer;
  r, g, b: Integer;
begin
  c := ColorToRGB(AColor);
  r := Round(GetRValue(c) * AFactor);
  g := Round(GetGValue(c) * AFactor);
  b := Round(GetBValue(c) * AFactor);
  if r > 255 then r := 255;
  if g > 255 then g := 255;
  if b > 255 then b := 255;
  Result := RGB(r, g, b);
end;

function Mix(AFrom, ATo: TColor; AT: Double): TColor;
var
  a, b: Integer;
begin
  a := ColorToRGB(AFrom);
  b := ColorToRGB(ATo);
  Result := RGB(
    Round(GetRValue(a) + (GetRValue(b) - GetRValue(a)) * AT),
    Round(GetGValue(a) + (GetGValue(b) - GetGValue(a)) * AT),
    Round(GetBValue(a) + (GetBValue(b) - GetBValue(a)) * AT));
end;

{ green low, amber high, red at the top of the scale }
function LevelColor(AFrac: Double): TColor;
begin
  if AFrac < 0.62 then Result := Mix($20C040, $40E060, AFrac / 0.62)
  else if AFrac < 0.84 then Result := Mix($40E060, $20C8F0, (AFrac - 0.62) / 0.22)
  else Result := Mix($20C8F0, $2830F0, (AFrac - 0.84) / 0.16);
end;

function DbFrac(ADb: Double): Double;
begin
  Result := (ADb - BOT_DB) / (TOP_DB - BOT_DB);
  if Result < 0 then Result := 0 else if Result > 1 then Result := 1;
end;

function HzText(AHz: Double): string;
begin
  if AHz >= 1000 then Result := Format('%.3g kHz', [AHz / 1000])
  else Result := Format('%.0f Hz', [AHz]);
end;

procedure TfrmSpectrum.FormShow(Sender: TObject);
begin
  tmrAnim.Enabled := True;
end;

procedure TfrmSpectrum.FormHide(Sender: TObject);
begin
  tmrAnim.Enabled := False;
end;

procedure TfrmSpectrum.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then Close;
end;

procedure TfrmSpectrum.Feed(const ADb: array of Double; ARate: Integer; AActive: Boolean);
var
  i: Integer;
begin
  if Length(FDb) <> Length(ADb) then SetLength(FDb, Length(ADb));
  for i := 0 to High(ADb) do FDb[i] := ADb[i];
  FRate := ARate;
  FActive := AActive;
end;

function TfrmSpectrum.BandCount: Integer;
begin
  Result := (pbView.Width - MARGIN_L - MARGIN_R) div 14;
  if Result < 16 then Result := 16;
  if Result > 96 then Result := 96;
end;

function TfrmSpectrum.BandEdgeHz(AIndex, ACount: Integer): Double;
var
  top: Double;
begin
  top := MAX_HZ;
  if (FRate > 0) and (FRate / 2 < top) then top := FRate / 2;
  Result := MIN_HZ * FastExp(FastLn(top / MIN_HZ) * AIndex / ACount);
end;

{ one animation frame: take each band's loudest bin, rise at once, fall smoothly, hold the cap }
procedure TfrmSpectrum.Analyse;
var
  n, bands, k, bin0, bin1, b: Integer;
  nyq, db, mx: Double;
begin
  bands := BandCount;
  if Length(FLevel) <> bands then
  begin
    SetLength(FLevel, bands);
    SetLength(FPeak, bands);
    SetLength(FHold, bands);
    for k := 0 to bands - 1 do
    begin
      FLevel[k] := BOT_DB;
      FPeak[k] := BOT_DB;
      FHold[k] := 0;
    end;
  end;
  n := Length(FDb);
  nyq := FRate / 2;
  FPeakDb := BOT_DB;
  FPeakHz := 0;
  for k := 0 to bands - 1 do
  begin
    db := BOT_DB;
    if FActive and (n > 1) and (nyq > 0) then
    begin
      bin0 := Round(BandEdgeHz(k, bands) / nyq * (n - 1));
      bin1 := Round(BandEdgeHz(k + 1, bands) / nyq * (n - 1));
      if bin1 < bin0 then bin1 := bin0;
      if bin1 > n - 1 then bin1 := n - 1;
      if bin0 > n - 1 then bin0 := n - 1;
      mx := BOT_DB;
      for b := bin0 to bin1 do
        if FDb[b] > mx then mx := FDb[b];
      db := mx;
    end;
    if db > TOP_DB then db := TOP_DB;
    if db >= FLevel[k] then FLevel[k] := db
    else FLevel[k] := Max(db, FLevel[k] - FALL_DB);
    if FLevel[k] >= FPeak[k] then
    begin
      FPeak[k] := FLevel[k];
      FHold[k] := HOLD_FRAMES;
    end
    else if FHold[k] > 0 then Dec(FHold[k])
    else FPeak[k] := Max(FLevel[k], FPeak[k] - PEAK_FALL_DB);
    if FLevel[k] > FPeakDb then
    begin
      FPeakDb := FLevel[k];
      FPeakHz := Sqrt(BandEdgeHz(k, bands) * BandEdgeHz(k + 1, bands));
    end;
  end;
end;

procedure TfrmSpectrum.tmrAnimTimer(Sender: TObject);
begin
  Analyse;
  pbView.Invalidate;
end;

procedure TfrmSpectrum.pbViewPaint(Sender: TObject);
var
  cv: TGLCanvas;
  w, h, bands, k, i, segs, lit, litPeak: Integer;
  px, py, pw, ph, bw, bgap, x, dx, dy, segH, y0, ySeg, yTop, floorY: Integer;
  hz, f: Double;
  txt: string;
  floorPoly: TArray<TPoint>;
  gi: Integer;
  topHz: Double;

  procedure Vertical(const ARect: TRect; ATop, ABottom: TColor);
  var
    r: Integer;
  begin
    for r := ARect.Top to ARect.Bottom - 1 do
    begin
      cv.Brush.Color := Mix(ATop, ABottom, (r - ARect.Top) / Max(1, ARect.Bottom - ARect.Top - 1));
      cv.FillRect(Rect(ARect.Left, r, ARect.Right, r + 1));
    end;
  end;

  procedure Text(AX, AY: Integer; const S: string; AColor: TColor; ASize: Integer; ABold: Boolean = False);
  begin
    cv.Brush.Style := bsClear;
    cv.Font.Size := ASize;
    cv.Font.Color := AColor;
    if ABold then cv.Font.Style := [fsBold] else cv.Font.Style := [];
    cv.TextOut(AX, AY, S);
    cv.Brush.Style := bsSolid;
  end;

  function DbY(ADb: Double): Integer;
  begin
    Result := py + ph - Round(DbFrac(ADb) * ph);
  end;

begin
  cv := pbView.GL;
  w := pbView.Width;
  h := pbView.Height;
  cv.Alpha := 1;
  cv.Pen.Style := psClear;
  cv.Brush.Style := bsSolid;

  { room: a deep blue-black gradient }
  Vertical(Rect(0, 0, w, h), $2A1A12, $080505);

  { title strip }
  Vertical(Rect(0, 0, w, 44), $4A3828, $201610);
  cv.Brush.Color := $705030;
  cv.FillRect(Rect(0, 43, w, 44));
  Text(18, 8, 'AUDIO SPECTRUM', $F0E0C8, 13, True);
  if FRate > 0 then
    Text(w - 230, 14, Format('Master output  -  %d Hz', [FRate]), $B09878, 9)
  else
    Text(w - 230, 14, 'Master output', $B09878, 9);

  px := MARGIN_L;
  py := MARGIN_T;
  pw := w - MARGIN_L - MARGIN_R;
  ph := h - MARGIN_T - MARGIN_B;
  if (pw < 120) or (ph < 80) then Exit;
  bands := BandCount;
  if Length(FLevel) <> bands then Analyse;
  bgap := 3;
  bw := Max(4, (pw - bgap * (bands + 1)) div bands);
  dx := Max(3, bw div 3);
  dy := dx div 2 + 1;
  floorY := py + ph;
  topHz := MAX_HZ;
  if (FRate > 0) and (FRate / 2 < topHz) then topHz := FRate / 2;

  { back wall, lifted by the bar depth so the bars stand in front of it, and the floor in front }
  Vertical(Rect(px + dx, py - dy, px + pw + dx, floorY - dy), $3C2A1C, $150E0A);
  floorPoly := [Point(px, floorY), Point(px + pw, floorY), Point(px + pw + dx, floorY - dy), Point(px + dx, floorY - dy)];
  cv.Brush.Color := $281C14;
  cv.Polygon(floorPoly);
  { side wall for depth }
  cv.Brush.Color := $1A120C;
  cv.Polygon([Point(px, py), Point(px + dx, py - dy), Point(px + dx, floorY - dy), Point(px, floorY)]);

  { dB grid on the back wall, every 10 dB }
  cv.Pen.Style := psSolid;
  cv.Pen.Width := 1;
  i := 0;
  while i >= Round(BOT_DB) do
  begin
    cv.Pen.Color := Mix($3C2A1C, $806040, IfThen(i = 0, 0.9, 0.45));
    cv.MoveTo(px + dx, DbY(i) - dy);
    cv.LineTo(px + pw + dx, DbY(i) - dy);
    cv.Pen.Color := $604830;
    cv.MoveTo(px, DbY(i));
    cv.LineTo(px + dx, DbY(i) - dy);
    txt := Format('%d', [i]);
    Text(px - 8 - cv.TextWidth(txt), DbY(i) - 7, txt, $A89070, 8);
    Dec(i, 10);
  end;
  { frequency grid: 100 Hz / 1 kHz / 10 kHz and friends }
  for gi := 0 to High(GRID_HZ) do
  begin
    hz := GRID_HZ[gi];
    if (hz > topHz) then Break;
    f := FastLn(hz / MIN_HZ) / FastLn(topHz / MIN_HZ);
    x := px + Round(f * pw);
    cv.Pen.Color := Mix($3C2A1C, $806040, 0.55);
    cv.MoveTo(x + dx, py - dy);
    cv.LineTo(x + dx, floorY - dy);
    cv.Pen.Color := $604830;
    cv.MoveTo(x, floorY);
    cv.LineTo(x + dx, floorY - dy);
    txt := HzText(hz);
    Text(x - cv.TextWidth(txt) div 2, floorY + 6, txt, $A89070, 8);
  end;  cv.Pen.Style := psClear;

  { the bars: segmented lit blocks, a top face and a side face for depth }
  segH := 5;
  segs := ph div (segH + 1);
  for k := 0 to bands - 1 do
  begin
    x := px + bgap + k * (bw + bgap);
    lit := Round(DbFrac(FLevel[k]) * segs);
    litPeak := Round(DbFrac(FPeak[k]) * segs);
    y0 := floorY;
    { reflection first, on the floor, fading with distance }
    for i := 0 to Min(lit, segs div 3) - 1 do
    begin
      cv.Alpha := 0.30 * (1 - i / Max(1, segs div 3));
      cv.Brush.Color := LevelColor(i / segs);
      ySeg := floorY + 3 + i * (segH + 1);
      cv.FillRect(Rect(x, ySeg, x + bw, ySeg + segH));
    end;
    cv.Alpha := 1;
    if lit > 0 then
    begin
      yTop := y0 - lit * (segH + 1) + 1;
      { side face and top face of the whole bar }
      cv.Brush.Color := Shade(LevelColor(lit / segs), 0.45);
      cv.Polygon([Point(x + bw, yTop), Point(x + bw + dx, yTop - dy), Point(x + bw + dx, y0 - dy), Point(x + bw, y0)]);
      cv.Brush.Color := Shade(LevelColor(lit / segs), 1.35);
      cv.Polygon([Point(x, yTop), Point(x + dx, yTop - dy), Point(x + bw + dx, yTop - dy), Point(x + bw, yTop)]);
      { front face: lit blocks, each its own level colour with a bright upper edge }
      for i := 0 to lit - 1 do
      begin
        ySeg := y0 - (i + 1) * (segH + 1) + 1;
        cv.Brush.Color := LevelColor(i / segs);
        cv.FillRect(Rect(x, ySeg, x + bw, ySeg + segH));
        cv.Brush.Color := Shade(LevelColor(i / segs), 1.4);
        cv.FillRect(Rect(x, ySeg, x + bw, ySeg + 1));
        cv.Brush.Color := Shade(LevelColor(i / segs), 0.7);
        cv.FillRect(Rect(x + bw - 1, ySeg, x + bw, ySeg + segH));
      end;
      { glow over the top of the bar }
      cv.Alpha := 0.16;
      cv.Brush.Color := LevelColor(lit / segs);
      cv.FillRect(Rect(x - 2, yTop - 6, x + bw + 2, yTop + 2));
      cv.Alpha := 1;
    end;
    { peak-hold cap }
    if litPeak > 0 then
    begin
      ySeg := y0 - litPeak * (segH + 1) - 1;
      cv.Brush.Color := $F8F8F8;
      cv.FillRect(Rect(x, ySeg, x + bw, ySeg + 3));
      cv.Brush.Color := $A0A0A0;
      cv.Polygon([Point(x + bw, ySeg), Point(x + bw + dx, ySeg - dy), Point(x + bw + dx, ySeg + 3 - dy), Point(x + bw, ySeg + 3)]);
    end;
  end;

  { floor edge highlight and the glossy sheen over the reflection }
  cv.Brush.Color := $A08060;
  cv.FillRect(Rect(px, floorY, px + pw, floorY + 1));
  for i := 0 to 17 do
  begin
    cv.Alpha := 0.55 * (i / 17.0);
    cv.Brush.Color := $080505;
    cv.FillRect(Rect(px, floorY + 2 + i * 3, px + pw + dx, floorY + 5 + i * 3));
  end;
  cv.Alpha := 1;

  { read-outs }
  Text(px, h - 26, 'Peak', $A89070, 9);
  if FActive and (FPeakDb > BOT_DB + 1) then
    Text(px + 40, h - 28, Format('%.1f dB  at  %s', [FPeakDb, HzText(FPeakHz)]), $F0E0C8, 11, True)
  else
    Text(px + 40, h - 28, 'waiting for audio - press Play on the Timeline', $807058, 10);
  txt := 'Esc closes';
  Text(w - MARGIN_R - cv.TextWidth(txt), h - 24, txt, $806850, 8);
end;

end.
