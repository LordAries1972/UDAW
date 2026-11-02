unit UDAW.UI.MeterForm;
{$I udaw.inc}

{ Live loudness and phase meters for the master output: momentary, short-term
  and integrated loudness (LUFS) against the common -23 / -14 LUFS delivery
  targets, true peak (dBTP) per channel, and the stereo phase correlation.
  The numbers are the master strip's own meters (written by the mixer thread,
  read here on a timer), so they are exactly what the Mixer tab shows.  Every
  control is placed at design time; only the bars are painted at run time. }

interface

uses
  Winapi.Windows, SysUtils, Classes, Math, Graphics, Controls, Forms, ExtCtrls,
  StdCtrls, UDAW.GL.Canvas, UDAW.GL.Widgets, UDAW.Mixer.Model;

type
  TMeterStripProvider = function: TMixStrip of object;

  TfrmMeters = class(TForm)
    pbMeters: TGLView;
    pnlBottom: TPanel;
    btnReset: TButton;
    lblTargets: TGLLabel;
    lblSource: TGLLabel;
    cboSource: TGLCombo;
    tmrMeters: TTimer;
    procedure pbMetersPaint(Sender: TObject);
    procedure tmrMetersTimer(Sender: TObject);
    procedure btnResetClick(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure FormHide(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
  private
    FProvider: TMeterStripProvider;
    procedure DrawBar(ACanvas: TGLCanvas; const ACaption, AText: string; AValue, AMin, AMax: Double;
      AX, AY, AW, AH: Integer; AWarnFrom, ARedFrom: Double);
    procedure DrawTick(ACanvas: TGLCanvas; AValue, AMin, AMax: Double; AX, AY, AW, AH: Integer;
      const ALabel: string);
  public
    property StripProvider: TMeterStripProvider read FProvider write FProvider;
    { 0 = automatic (follows what is playing), 1 = the Timeline mixer, 2 = the Tracker module's mixer }
    function SourceIndex: Integer;
  end;

implementation

{$R *.dfm}

const
  LUFS_MIN = -50.0;
  LUFS_MAX = -5.0;
  TP_MIN = -60.0;
  TP_MAX = 3.0;
  SEG_N = 41;     { every meter is this many identical lit/unlit segments (odd, so Phase has a centre segment) }
  SEG_GAP = 2;
  SEG_GREEN = $50C050;
  SEG_AMBER = $30C0F0;
  SEG_RED = $3030E0;

function Shade(AColor: TColor; AFactor: Double): TColor;
var
  c, r, g, b: Integer;
begin
  c := ColorToRGB(AColor);
  r := Min(255, Round(GetRValue(c) * AFactor));
  g := Min(255, Round(GetGValue(c) * AFactor));
  b := Min(255, Round(GetBValue(c) * AFactor));
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

{ a colour darkened for an unlit segment }
function Dim(AColor: TColor): TColor;
begin
  Result := Shade(AColor, 0.16);
end;

function SegWidth(ATotal: Integer): Integer;
begin
  Result := Max(3, (ATotal + SEG_GAP) div SEG_N - SEG_GAP);
end;

function Frac01(AValue, AMin, AMax: Double): Double;
begin
  if AMax <= AMin then Exit(0);
  Result := (AValue - AMin) / (AMax - AMin);
  if Result < 0 then Result := 0 else if Result > 1 then Result := 1;
end;

{ A vertical gradient. ARadius > 0 rounds its four corners (each row is inset by the corner's
  curve), so a gradient laid inside a rounded panel follows the panel's corners instead of
  squaring them off. }
procedure VGrad(ACanvas: TGLCanvas; const R: TRect; ATop, ABottom: TColor; ARadius: Integer = 0);
var
  y, d, inset: Integer;
  dy: Double;
begin
  ACanvas.Pen.Style := psClear;
  ACanvas.Brush.Style := bsSolid;
  for y := R.Top to R.Bottom - 1 do
  begin
    ACanvas.Brush.Color := Mix(ATop, ABottom, (y - R.Top) / Max(1, R.Bottom - R.Top - 1));
    inset := 0;
    if ARadius > 0 then
    begin
      d := Min(y - R.Top, R.Bottom - 1 - y);
      if d < ARadius then
      begin
        dy := ARadius - d - 0.5;
        inset := Ceil(ARadius - Sqrt(Max(0.0, ARadius * ARadius - dy * dy)));
      end;
    end;
    ACanvas.FillRect(Rect(R.Left + inset, y, R.Right - inset, y + 1));
  end;
end;

procedure HLine(ACanvas: TGLCanvas; X1, X2, Y: Integer; AColor: TColor);
begin
  ACanvas.Brush.Style := bsSolid;
  ACanvas.Brush.Color := AColor;
  ACanvas.FillRect(Rect(X1, Y, X2, Y + 1));
end;

procedure VLine(ACanvas: TGLCanvas; X, Y1, Y2: Integer; AColor: TColor);
begin
  ACanvas.Brush.Style := bsSolid;
  ACanvas.Brush.Color := AColor;
  ACanvas.FillRect(Rect(X, Y1, X + 1, Y2));
end;

{ a raised, rounded 3D section panel with a drop shadow and a title }
procedure Panel3D(ACanvas: TGLCanvas; const R: TRect; const ATitle: string);
begin
  ACanvas.Pen.Style := psClear;
  ACanvas.Brush.Style := bsSolid;
  ACanvas.Alpha := 0.40;
  ACanvas.Brush.Color := clBlack;
  ACanvas.RoundRect(R.Left + 4, R.Top + 5, R.Right + 4, R.Bottom + 5, 14, 14);
  ACanvas.Alpha := 1;
  ACanvas.Brush.Color := $2E2E34;
  ACanvas.RoundRect(R.Left, R.Top, R.Right, R.Bottom, 14, 14);
  VGrad(ACanvas, Rect(R.Left + 3, R.Top + 3, R.Right - 3, R.Bottom - 3), $44444C, $1C1C22, 4);
  { bevel: light along the top / left, dark along the bottom / right }
  HLine(ACanvas, R.Left + 6, R.Right - 6, R.Top + 1, $7A7A86);
  VLine(ACanvas, R.Left + 1, R.Top + 6, R.Bottom - 6, $5A5A66);
  HLine(ACanvas, R.Left + 6, R.Right - 6, R.Bottom - 2, $0C0C0E);
  VLine(ACanvas, R.Right - 2, R.Top + 6, R.Bottom - 6, $101014);
  ACanvas.Brush.Style := bsClear;
  ACanvas.Font.Size := 9;
  ACanvas.Font.Style := [fsBold];
  ACanvas.Font.Color := $E8D8B8;
  ACanvas.TextOut(R.Left + 16, R.Top + 9, ATitle);
  ACanvas.Font.Style := [];
  HLine(ACanvas, R.Left + 16, R.Right - 16, R.Top + 26, $14141A);
  HLine(ACanvas, R.Left + 16, R.Right - 16, R.Top + 27, $5A5A66);
end;

{ a recessed trough the segments sit in }
procedure Trough(ACanvas: TGLCanvas; const R: TRect);
begin
  ACanvas.Pen.Style := psClear;
  ACanvas.Brush.Style := bsSolid;
  { the trough stands proud of the panel: a soft drop shadow beneath it }
  ACanvas.Brush.Color := clBlack;
  ACanvas.Alpha := 0.30;
  ACanvas.RoundRect(R.Left - 5, R.Top - 1, R.Right + 5, R.Bottom + 7, 10, 10);
  ACanvas.Alpha := 0.45;
  ACanvas.RoundRect(R.Left - 4, R.Top, R.Right + 4, R.Bottom + 5, 8, 8);
  ACanvas.Alpha := 1;
  ACanvas.Brush.Color := $08080A;
  ACanvas.RoundRect(R.Left - 4, R.Top - 3, R.Right + 4, R.Bottom + 3, 7, 7);
  HLine(ACanvas, R.Left - 2, R.Right + 2, R.Top - 3, $020203);          // shadow on the top lip
  HLine(ACanvas, R.Left - 2, R.Right + 2, R.Bottom + 2, $48484E);        // light catching the bottom lip
end;

{ one 3D block: lit ones are domed with a bright top edge and a soft glow, unlit ones are dark glass }
procedure Block(ACanvas: TGLCanvas; const R: TRect; AColor: TColor; ALit: Boolean);
var
  mid: Integer;
begin
  ACanvas.Pen.Style := psClear;
  ACanvas.Brush.Style := bsSolid;
  { each block casts a small shadow onto the trough floor }
  ACanvas.Brush.Color := clBlack;
  ACanvas.Alpha := 0.55;
  ACanvas.FillRect(Rect(R.Left + 1, R.Bottom, R.Right + 1, R.Bottom + 2));
  ACanvas.Alpha := 1;
  if ALit then
  begin
    ACanvas.Alpha := 0.20;
    ACanvas.Brush.Color := AColor;
    ACanvas.FillRect(Rect(R.Left - 1, R.Top - 2, R.Right + 1, R.Bottom + 2));
    ACanvas.Alpha := 1;
    mid := (R.Top + R.Bottom) div 2;
    ACanvas.Brush.Color := Shade(AColor, 1.25);
    ACanvas.FillRect(Rect(R.Left, R.Top, R.Right, mid));
    ACanvas.Brush.Color := Shade(AColor, 0.78);
    ACanvas.FillRect(Rect(R.Left, mid, R.Right, R.Bottom));
    ACanvas.Brush.Color := Shade(AColor, 1.7);
    ACanvas.FillRect(Rect(R.Left, R.Top, R.Right, R.Top + 1));
    ACanvas.FillRect(Rect(R.Left, R.Top, R.Left + 1, R.Bottom));
    ACanvas.Brush.Color := Shade(AColor, 0.45);
    ACanvas.FillRect(Rect(R.Left, R.Bottom - 1, R.Right, R.Bottom));
    ACanvas.FillRect(Rect(R.Right - 1, R.Top, R.Right, R.Bottom));
  end
  else
  begin
    ACanvas.Brush.Color := Dim(AColor);
    ACanvas.FillRect(R);
    ACanvas.Brush.Color := Shade(AColor, 0.30);
    ACanvas.FillRect(Rect(R.Left, R.Top, R.Right, R.Top + 1));
    ACanvas.Brush.Color := Shade(AColor, 0.08);
    ACanvas.FillRect(Rect(R.Left, R.Bottom - 1, R.Right, R.Bottom));
  end;
end;

{ the numeric read-out in an LCD-style recessed window }
procedure Readout(ACanvas: TGLCanvas; const R: TRect; const AText: string; AColor: TColor);
begin
  ACanvas.Pen.Style := psClear;
  ACanvas.Brush.Style := bsSolid;
  ACanvas.Brush.Color := $050607;
  ACanvas.RoundRect(R.Left, R.Top, R.Right, R.Bottom, 6, 6);
  HLine(ACanvas, R.Left + 3, R.Right - 3, R.Top, $000000);
  HLine(ACanvas, R.Left + 3, R.Right - 3, R.Bottom - 1, $50505A);
  ACanvas.Alpha := 0.10;
  ACanvas.Brush.Color := AColor;
  ACanvas.FillRect(Rect(R.Left + 2, R.Top + 2, R.Right - 2, (R.Top + R.Bottom) div 2));
  ACanvas.Alpha := 1;
  ACanvas.Brush.Style := bsClear;
  ACanvas.Font.Size := 10;
  ACanvas.Font.Style := [fsBold];
  ACanvas.Font.Color := AColor;
  ACanvas.TextOut(R.Right - 8 - ACanvas.TextWidth(AText), R.Top + (R.Bottom - R.Top - ACanvas.TextHeight(AText)) div 2, AText);
  ACanvas.Font.Style := [];
end;

function TfrmMeters.SourceIndex: Integer;
begin
  Result := Max(0, cboSource.ItemIndex);
end;

procedure TfrmMeters.FormShow(Sender: TObject);
begin
  tmrMeters.Enabled := True;
end;

procedure TfrmMeters.FormHide(Sender: TObject);
begin
  tmrMeters.Enabled := False;
end;

procedure TfrmMeters.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_ESCAPE) and (Shift = []) then
  begin
    Key := 0;
    Close;
  end;
end;

procedure TfrmMeters.tmrMetersTimer(Sender: TObject);
begin
  pbMeters.Invalidate;
end;

procedure TfrmMeters.btnResetClick(Sender: TObject);
var
  s: TMixStrip;
begin
  if Assigned(FProvider) then
  begin
    s := FProvider();
    if s <> nil then s.ResetMeters;
  end;
  pbMeters.Invalidate;
end;

{ a target marker across a group of bars (AY..AY+AH), labelled underneath }
procedure TfrmMeters.DrawTick(ACanvas: TGLCanvas; AValue, AMin, AMax: Double; AX, AY, AW, AH: Integer;
  const ALabel: string);
var
  x, segW: Integer;
begin
  segW := SegWidth(AW);
  x := AX + Trunc(Frac01(AValue, AMin, AMax) * SEG_N) * (segW + SEG_GAP) - SEG_GAP div 2 - 1;
  ACanvas.Alpha := 0.85;
  VLine(ACanvas, x, AY - 5, AY + AH + 4, $F0F0F0);
  ACanvas.Alpha := 1;
  ACanvas.Brush.Style := bsClear;
  ACanvas.Font.Size := 7;
  ACanvas.Font.Style := [];
  ACanvas.Font.Color := $C8C8D0;
  ACanvas.TextOut(x - ACanvas.TextWidth(ALabel) div 2, AY + AH + 6, ALabel);
end;

procedure TfrmMeters.DrawBar(ACanvas: TGLCanvas; const ACaption, AText: string; AValue, AMin, AMax: Double;
  AX, AY, AW, AH: Integer; AWarnFrom, ARedFrom: Double);
var
  i, segW: Integer;
  frac, segFrac, segVal: Double;
  col: TColor;
begin
  ACanvas.Font.Size := 9;
  ACanvas.Font.Style := [];
  ACanvas.Font.Color := $D0D0D8;
  ACanvas.Brush.Style := bsClear;
  ACanvas.TextOut(AX - 98, AY + (AH - ACanvas.TextHeight(ACaption)) div 2, ACaption);
  Trough(ACanvas, Rect(AX, AY, AX + AW, AY + AH));
  frac := Frac01(AValue, AMin, AMax);
  segW := SegWidth(AW);
  for i := 0 to SEG_N - 1 do
  begin
    { the segment's own level decides its colour; it is lit once the value reaches its middle }
    segFrac := (i + 0.5) / SEG_N;
    segVal := AMin + segFrac * (AMax - AMin);
    if segVal >= ARedFrom then col := SEG_RED
    else if segVal >= AWarnFrom then col := SEG_AMBER
    else col := SEG_GREEN;
    Block(ACanvas, Rect(AX + i * (segW + SEG_GAP), AY, AX + i * (segW + SEG_GAP) + segW, AY + AH), col, segFrac <= frac);
  end;
  if AValue >= ARedFrom then col := SEG_RED
  else if AValue >= AWarnFrom then col := SEG_AMBER
  else col := $60F060;
  Readout(ACanvas, Rect(AX + AW + 14, AY - 2, AX + AW + 14 + 104, AY + AH + 2), AText, col);
end;

procedure TfrmMeters.pbMetersPaint(Sender: TObject);
const
  PAD = 14;
  INNER = 16;
  LABEL_W = 100;
  VAL_W = 120;
  BAR_H = 22;
  BAR_GAP = 9;
  HEAD_H = 36;
  FOOT_H = 26;
  PANEL_GAP = 14;
var
  cv: TGLCanvas;
  s: TMixStrip;
  w, h, barW, x0, y, py, ph, cx, i, segW, mid, litTo: Integer;
  corr: Double;
  col: TColor;

  function PanelHeight(ABars: Integer): Integer;
  begin
    Result := HEAD_H + ABars * BAR_H + (ABars - 1) * BAR_GAP + FOOT_H;
  end;

begin
  cv := pbMeters.GL;
  w := pbMeters.Width;
  h := pbMeters.Height;
  cv.Alpha := 1;
  VGrad(cv, Rect(0, 0, w, h), $2A2A30, $0C0C10);
  s := nil;
  if Assigned(FProvider) then s := FProvider();
  if s = nil then
  begin
    cv.Font.Color := clSilver;
    cv.Brush.Style := bsClear;
    cv.TextOut(12, 12, 'No project open.');
    Exit;
  end;
  barW := w - 2 * PAD - 2 * INNER - LABEL_W - VAL_W - 14;
  if barW < 120 then barW := 120;
  barW := SEG_N * (SegWidth(barW) + SEG_GAP) - SEG_GAP;   { snap to a whole number of equal segments }
  x0 := PAD + INNER + LABEL_W;
  segW := SegWidth(barW);

  { ---- loudness ---- }
  py := PAD;
  ph := PanelHeight(3);
  Panel3D(cv, Rect(PAD, py, w - PAD, py + ph), 'LOUDNESS  (LUFS)');
  y := py + HEAD_H;
  DrawBar(cv, 'Momentary', Format('%.1f LUFS', [s.MeterLufs]), s.MeterLufs, LUFS_MIN, LUFS_MAX,
    x0, y, barW, BAR_H, -14.0, -9.0);
  Inc(y, BAR_H + BAR_GAP);
  DrawBar(cv, 'Short-term', Format('%.1f LUFS', [s.MeterLufsShort]), s.MeterLufsShort, LUFS_MIN, LUFS_MAX,
    x0, y, barW, BAR_H, -14.0, -9.0);
  Inc(y, BAR_H + BAR_GAP);
  DrawBar(cv, 'Integrated', Format('%.1f LUFS', [s.MeterLufsIntegrated]), s.MeterLufsIntegrated,
    LUFS_MIN, LUFS_MAX, x0, y, barW, BAR_H, -14.0, -9.0);
  { delivery targets across the three loudness bars }
  DrawTick(cv, -23.0, LUFS_MIN, LUFS_MAX, x0, py + HEAD_H, barW, 3 * BAR_H + 2 * BAR_GAP, '-23');
  DrawTick(cv, -14.0, LUFS_MIN, LUFS_MAX, x0, py + HEAD_H, barW, 3 * BAR_H + 2 * BAR_GAP, '-14');

  { ---- peaks ---- }
  py := py + ph + PANEL_GAP;
  ph := PanelHeight(3);
  Panel3D(cv, Rect(PAD, py, w - PAD, py + ph), 'PEAK LEVELS  (dBFS / dBTP)');
  y := py + HEAD_H;
  DrawBar(cv, 'Peak L', Format('%.1f dBFS', [s.MeterPeakDbL]), s.MeterPeakDbL, TP_MIN, TP_MAX,
    x0, y, barW, BAR_H, -6.0, -1.0);
  Inc(y, BAR_H + BAR_GAP);
  DrawBar(cv, 'Peak R', Format('%.1f dBFS', [s.MeterPeakDbR]), s.MeterPeakDbR, TP_MIN, TP_MAX,
    x0, y, barW, BAR_H, -6.0, -1.0);
  Inc(y, BAR_H + BAR_GAP);
  DrawBar(cv, 'True peak', Format('%.1f dBTP', [s.MeterTruePeakDb]), s.MeterTruePeakDb, TP_MIN, TP_MAX,
    x0, y, barW, BAR_H, -6.0, -1.0);
  DrawTick(cv, -1.0, TP_MIN, TP_MAX, x0, py + HEAD_H, barW, 3 * BAR_H + 2 * BAR_GAP, '-1 dBTP');

  { ---- phase correlation: -1 (out of phase) .. 0 .. +1 (mono) ---- }
  py := py + ph + PANEL_GAP;
  ph := PanelHeight(1);
  Panel3D(cv, Rect(PAD, py, w - PAD, py + ph), 'STEREO PHASE  (correlation)');
  y := py + HEAD_H;
  cv.Brush.Style := bsClear;
  cv.Font.Size := 9;
  cv.Font.Color := $D0D0D8;
  cv.TextOut(PAD + INNER, y + (BAR_H - cv.TextHeight('Phase')) div 2, 'Phase');
  corr := s.MeterCorrelation;
  if corr < -1 then corr := -1 else if corr > 1 then corr := 1;
  Trough(cv, Rect(x0, y, x0 + barW, y + BAR_H));
  mid := SEG_N div 2;
  { the middle segment is 0; segments fill outward from it - green toward +1 (mono), red toward -1 (out of phase) }
  litTo := Round(corr * mid);
  for i := 0 to SEG_N - 1 do
  begin
    if i >= mid then col := SEG_GREEN else col := SEG_RED;
    Block(cv, Rect(x0 + i * (segW + SEG_GAP), y, x0 + i * (segW + SEG_GAP) + segW, y + BAR_H), col,
      ((litTo >= 0) and (i >= mid) and (i <= mid + litTo)) or ((litTo < 0) and (i <= mid) and (i >= mid + litTo)));
  end;
  cx := x0 + mid * (segW + SEG_GAP) + segW div 2;
  cv.Alpha := 0.85;
  VLine(cv, cx, y - 5, y + BAR_H + 4, $F0F0F0);
  cv.Alpha := 1;
  cv.Brush.Style := bsClear;
  cv.Font.Size := 7;
  cv.Font.Color := $C8C8D0;
  cv.TextOut(x0, y + BAR_H + 6, '-1');
  cv.TextOut(cx - cv.TextWidth('0') div 2, y + BAR_H + 6, '0');
  cv.TextOut(x0 + barW - cv.TextWidth('+1'), y + BAR_H + 6, '+1');
  if corr < 0 then col := SEG_RED else col := $60F060;
  Readout(cv, Rect(x0 + barW + 14, y - 2, x0 + barW + 14 + 104, y + BAR_H + 2), Format('%.2f', [corr]), col);
end;

end.
