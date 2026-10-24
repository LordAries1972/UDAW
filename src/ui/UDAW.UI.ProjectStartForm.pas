unit UDAW.UI.ProjectStartForm;

{ Project Startup screen: the window shown when UDAW has finished starting. It
  replaces the old top-level Project tab as the place to begin work - New
  project, Open project, the last five projects (file names only), Help and
  About, plus the current version and a "Show on Startup" check box.

  The window is borderless with a rounded outline (SetWindowRgn) and carries a
  single close icon placed well inside the curved region. The header - the
  large "Welcome to UDAW" title with its extruded 3D lettering and the raised
  separator bar beneath it - is painted here; every control (OpenGL 3.3 GL
  widgets) is placed at design time in the .dfm, per the project's forms rule.
  All colours derive from the active VCL style so the screen follows the theme.

  The form only reports what the user chose (Choice / RecentPath /
  ShowOnStartup); the main form carries it out and persists the setting. }

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Types,
  System.UITypes, System.Math, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Themes, Vcl.ExtCtrls,
  Winapi.GDIPAPI, Winapi.GDIPOBJ,
  UDAW.GL.Canvas, UDAW.GL.Widgets;

const
  PROJECT_START_RECENT_COUNT = 5;

type
  TProjectStartChoice = (pscNone, pscNew, pscOpen, pscRecent, pscHelp, pscAbout);

  TfrmProjectStart = class(TForm, IGLBackdrop)
    pnlBody: TGLPanel;
    lblVersion: TGLLabel;
    lblStart: TGLLabel;
    lblLearn: TGLLabel;
    lblRecent: TGLLabel;
    lblTagline: TGLLabel;
    btnNew: TGLButton;
    btnOpen: TGLButton;
    btnHelp: TGLButton;
    btnAbout: TGLButton;
    btnRecent0: TGLButton;
    btnRecent1: TGLButton;
    btnRecent2: TGLButton;
    btnRecent3: TGLButton;
    btnRecent4: TGLButton;
    chkShowOnStartup: TGLCheck;
    bvlOpenSep: TGLShineBar;
    tmrShine: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure btnNewClick(Sender: TObject);
    procedure btnOpenClick(Sender: TObject);
    procedure btnHelpClick(Sender: TObject);
    procedure btnAboutClick(Sender: TObject);
    procedure btnRecentClick(Sender: TObject);
    procedure tmrShineTimer(Sender: TObject);
  private
    FChoice: TProjectStartChoice;
    FRecentPath: string;
    FCloseHot: Boolean;
    FCloseDown: Boolean;
    FShinePhase: Double;
    FRecent: array[0..PROJECT_START_RECENT_COUNT - 1] of string;
    procedure Choose(AChoice: TProjectStartChoice);
    function GetShowOnStartup: Boolean;
    procedure WMNCHitTest(var Msg: TWMNCHitTest); message WM_NCHITTEST;
    function CloseRect: TRect;
    procedure InvalidateClose;
    procedure SetCloseHot(AValue: Boolean);
    procedure PaintCloseIcon;
    procedure PaintGlisten(const ARect: TRect; APhaseShift: Double);
    procedure PaintSparkle(CX, CY: Integer; ALife: Double);
    procedure WMNCMouseMove(var Msg: TWMNCMouseMove); message WM_NCMOUSEMOVE;
    procedure CMMouseLeave(var Msg: TMessage); message CM_MOUSELEAVE;
    procedure UpdateRegion;
    function HeaderColorAt(Y: Integer): TColor;
    function GLBackdropColor(const ARect: TRect): TColor;
  protected
    procedure CreateWnd; override;
    procedure Resize; override;
    procedure DoShow; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure Paint; override;
  public
    { AVersionText is shown as-is; ARecent holds full paths, newest first (at
      most the first five are used); AShowOnStartup is the check box's start state }
    procedure Prepare(const AVersionText: string; const ARecent: TArray<string>;
      AShowOnStartup: Boolean);
    property Choice: TProjectStartChoice read FChoice;
    property RecentPath: string read FRecentPath;
    property ShowOnStartup: Boolean read GetShowOnStartup;
  end;

implementation

{$R *.dfm}

const
  HEADER_HEIGHT = 124;
  CORNER_DIAMETER = 44;
  TITLE_TEXT = 'Welcome to UDAW';

{ t = 0 gives A, t = 1 gives B }
function MixColor(A, B: TColor; T: Double): TColor;
var ca, cb: Integer;
begin
  T := EnsureRange(T, 0, 1);
  ca := ColorToRGB(A);
  cb := ColorToRGB(B);
  Result := RGB(
    Round(GetRValue(ca) + (GetRValue(cb) - GetRValue(ca)) * T),
    Round(GetGValue(ca) + (GetGValue(cb) - GetGValue(ca)) * T),
    Round(GetBValue(ca) + (GetBValue(cb) - GetBValue(ca)) * T));
end;

procedure TfrmProjectStart.FormCreate(Sender: TObject);
begin
  DoubleBuffered := True;
  { a real RGB value (not clBtnFace) so the GL widgets on the body use it as their backdrop }
  pnlBody.Color := ColorToRGB(StyleServices.GetSystemColor(clBtnFace));
end;

{ the rounded outline always follows the window's current size (it is rescaled for the screen's
  DPI after the handle exists, so a region made only at creation would cut the corners off) }
procedure TfrmProjectStart.UpdateRegion;
var rgn: HRGN;
begin
  if not HandleAllocated then Exit;
  rgn := CreateRoundRectRgn(0, 0, Width + 1, Height + 1, CORNER_DIAMETER, CORNER_DIAMETER);
  SetWindowRgn(Handle, rgn, True);   // the system owns the region from here on
end;

procedure TfrmProjectStart.CreateWnd;
begin
  inherited CreateWnd;
  UpdateRegion;
end;

procedure TfrmProjectStart.Resize;
begin
  inherited Resize;
  UpdateRegion;
end;

procedure TfrmProjectStart.DoShow;
begin
  inherited DoShow;
  UpdateRegion;
end;

{ the header gradient's colour on row Y: accent-tinted at the top, fading into the body colour }
function TfrmProjectStart.HeaderColorAt(Y: Integer): TColor;
var base, accent: TColor;
begin
  base := pnlBody.Color;
  accent := ColorToRGB(StyleServices.GetSystemColor(clHighlight));
  Result := MixColor(MixColor(base, accent, 0.40), base, EnsureRange(Y, 0, HEADER_HEIGHT) / HEADER_HEIGHT);
end;

{ what lies behind a transparent widget: the header gradient above the body, else the body colour }
function TfrmProjectStart.GLBackdropColor(const ARect: TRect): TColor;
begin
  if ARect.Top + (ARect.Bottom - ARect.Top) div 2 < HEADER_HEIGHT then
    Result := HeaderColorAt((ARect.Top + ARect.Bottom) div 2)
  else
    Result := pnlBody.Color;
end;

{ the header (title area) drags the window; the controls keep their own clicks }
procedure TfrmProjectStart.WMNCHitTest(var Msg: TWMNCHitTest);
var pt: TPoint;
begin
  inherited;
  if Msg.Result = HTCLIENT then
  begin
    pt := ScreenToClient(Point(Msg.XPos, Msg.YPos));
    if (pt.Y < HEADER_HEIGHT) and not PtInRect(CloseRect, pt) then Msg.Result := HTCAPTION;
  end;
end;

procedure TfrmProjectStart.Paint;
var
  base, accent, deep, bright: TColor;
  y, x, i, tw, th, tx, ty, barL, barR: Integer;
  t, tNow, glintPos, a, cr, cg, cb, mul, gl: Double;
  seed: Integer;
  hsh: UInt64;
begin
  base := pnlBody.Color;
  accent := ColorToRGB(StyleServices.GetSystemColor(clHighlight));
  deep := MixColor(accent, clBlack, 0.62);
  bright := MixColor(accent, clWhite, 0.78);

  { header: accent-tinted at the top fading into the body colour, so it meets the body seamlessly }
  for y := 0 to HEADER_HEIGHT - 1 do
  begin
    Canvas.Pen.Color := HeaderColorAt(y);
    Canvas.MoveTo(0, y);
    Canvas.LineTo(ClientWidth, y);
  end;
  { a soft sheen along the very top edge }
  for y := 0 to 5 do
  begin
    Canvas.Pen.Color := MixColor(MixColor(base, accent, 0.40), clWhite, 0.30 - y * 0.05);
    Canvas.MoveTo(CORNER_DIAMETER div 2, y);
    Canvas.LineTo(ClientWidth - CORNER_DIAMETER div 2, y);
  end;

  { the title: a stack of darker copies stepping down-right makes the extrusion, a wide soft
    shadow sits under it, and the lit face goes on top with a highlight copy one pixel up-left }
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Name := 'Segoe UI';
  Canvas.Font.Size := 30;
  Canvas.Font.Style := [fsBold];
  tw := Canvas.TextWidth(TITLE_TEXT);
  th := Canvas.TextHeight(TITLE_TEXT);
  tx := (ClientWidth - tw) div 2 - 4;
  ty := 20;
  for i := 12 downto 8 do
  begin
    Canvas.Font.Color := MixColor(MixColor(base, clBlack, 0.55), base, (12 - i) / 6);
    Canvas.TextOut(tx + i, ty + i, TITLE_TEXT);
  end;
  for i := 7 downto 1 do
  begin
    Canvas.Font.Color := MixColor(deep, accent, (7 - i) / 9);
    Canvas.TextOut(tx + i, ty + i, TITLE_TEXT);
  end;
  Canvas.Font.Color := bright;
  Canvas.TextOut(tx - 1, ty - 1, TITLE_TEXT);
  Canvas.Font.Color := MixColor(clWhite, accent, 0.12);
  Canvas.TextOut(tx, ty, TITLE_TEXT);
  { the glisten: clipped to the lettering itself, a slanted band of light glides across it }
  BeginPath(Canvas.Handle);
  Canvas.TextOut(tx, ty, TITLE_TEXT);
  EndPath(Canvas.Handle);
  SelectClipPath(Canvas.Handle, RGN_COPY);
  { solar glare, one pixel column at a time: a molten gold that shifts towards pale yellow, a
    bright glare that rolls across the lettering from right to left and bleaches it towards
    white-hot as it passes }
  tNow := GetTickCount64 / 1000.0;
  glintPos := tx + tw + 90 - Frac(tNow * 0.30) * (tw + 180);
  Canvas.Pen.Width := 1;
  for x := tx - 2 to tx + tw + 14 do
  begin
    a := 0.5 + 0.5 * Sin(x * 0.02 + tNow * 1.8);          // 0 = amber, 1 = pale yellow
    cr := 1.0;
    cg := 0.62 + 0.30 * a;
    cb := 0.12 + 0.50 * a;
    mul := 0.80 + 0.20 * (0.5 + 0.5 * Sin(x * 0.011 + tNow * 2.6));
    gl := 0.95 * Exp(-Sqr((x - glintPos) / 46));
    cr := cr * mul; cg := cg * mul; cb := cb * mul;
    cr := cr + (1 - cr) * gl; cg := cg + (1 - cg) * gl; cb := cb + (1 - cb) * gl;
    Canvas.Pen.Color := RGB(Round(cr * 255), Round(cg * 255), Round(cb * 255));
    Canvas.MoveTo(x, ty - 2);
    Canvas.LineTo(x, ty + th + 2);
  end;
  SelectClipRgn(Canvas.Handle, 0);
  { sparkles: points of light flaring and fading over the lettering, each at a fresh spot every cycle }
  for i := 0 to 11 do
  begin
    t := tNow / (1.1 + (i mod 4) * 0.23) + i * 0.37;   // this sparkle's clock; the whole part picks its spot
    seed := Trunc(t);
    t := Frac(t);
    hsh := ((UInt64(i + 1) * 73856093) xor (UInt64(seed + 1) * 19349663)) and $FFFFFFFF;
    PaintSparkle(tx + 6 + Integer(hsh mod UInt64(Max(1, tw - 12))),
      ty + 6 + Integer((hsh shr 13) mod UInt64(Max(1, th - 12))),
      Sqr(Sin(Pi * t)));
  end;

  { 3D separator bar: a shadow line, a gradient channel that glows in the middle, a light line
    underneath - reads as a raised rail }
  barL := 36;
  barR := ClientWidth - 36;
  y := ty + th + 14;
  for x := barL to barR do
  begin
    t := Sin(Pi * (x - barL) / (barR - barL));
    Canvas.Pen.Color := MixColor(base, deep, 0.5 + 0.5 * t);
    Canvas.MoveTo(x, y);        Canvas.LineTo(x + 1, y);
    Canvas.Pen.Color := MixColor(deep, accent, t);
    Canvas.MoveTo(x, y + 1);    Canvas.LineTo(x + 1, y + 1);
    Canvas.Pen.Color := MixColor(accent, bright, t);
    Canvas.MoveTo(x, y + 2);    Canvas.LineTo(x + 1, y + 2);
    Canvas.Pen.Color := MixColor(accent, deep, 0.35 + 0.3 * (1 - t));
    Canvas.MoveTo(x, y + 3);    Canvas.LineTo(x + 1, y + 3);
    Canvas.Pen.Color := MixColor(base, clWhite, 0.10 + 0.25 * t);
    Canvas.MoveTo(x, y + 4);    Canvas.LineTo(x + 1, y + 4);
  end;
  { the same glisten gliding along the rail, a little behind the title's }
  IntersectClipRect(Canvas.Handle, barL, y, barR, y + 5);
  PaintGlisten(Rect(barL, y, barR, y + 5), 0.5);
  SelectClipRgn(Canvas.Handle, 0);
  PaintCloseIcon;
end;

{ slanted band of light sweeping left to right over ARect (the caller sets the clip); APhaseShift
  offsets it within the cycle }
procedure TfrmProjectStart.PaintGlisten(const ARect: TRect; APhaseShift: Double);
var
  g: TGPGraphics;
  br: TGPSolidBrush;
  pts: array[0..3] of TGPPoint;
  sx, k, w, slant: Integer;
begin
  w := 90;
  slant := ARect.Bottom - ARect.Top;
  sx := ARect.Left - w - slant + Round(Frac(FShinePhase / 8.0 + APhaseShift) * (ARect.Right - ARect.Left + 2 * (w + slant)));
  g := TGPGraphics.Create(Canvas.Handle);
  try
    g.SetSmoothingMode(SmoothingModeAntiAlias);
    for k := 0 to 3 do
    begin
      br := TGPSolidBrush.Create(MakeColor(40 + 45 * k, 255, 255, 255));
      try
        pts[0] := MakePoint(sx + k * 10 + slant, ARect.Top);
        pts[1] := MakePoint(sx + w - k * 10 + slant, ARect.Top);
        pts[2] := MakePoint(sx + w - k * 10, ARect.Bottom);
        pts[3] := MakePoint(sx + k * 10, ARect.Bottom);
        g.FillPolygon(br, PGPPoint(@pts[0]), 4);
      finally
        br.Free;
      end;
    end;
  finally
    g.Free;
  end;
end;

{ one four-point sparkle at (CX, CY): a soft halo, a long vertical and horizontal flare and a white
  core; ALife (0..1) is how bright it is right now }
procedure TfrmProjectStart.PaintSparkle(CX, CY: Integer; ALife: Double);
var
  g: TGPGraphics;
  br: TGPSolidBrush;
  pts: array[0..3] of TGPPoint;
  rad, arm: Integer;
begin
  if ALife < 0.04 then Exit;
  arm := Round(5 + 17 * ALife);
  rad := Round(3 + 6 * ALife);
  g := TGPGraphics.Create(Canvas.Handle);
  try
    g.SetSmoothingMode(SmoothingModeAntiAlias);
    br := TGPSolidBrush.Create(MakeColor(Round(70 * ALife), 255, 236, 170));
    try
      g.FillEllipse(br, CX - rad * 2, CY - rad * 2, rad * 4, rad * 4);   // halo
    finally
      br.Free;
    end;
    br := TGPSolidBrush.Create(MakeColor(Round(235 * ALife), 255, 252, 235));
    try
      pts[0] := MakePoint(CX, CY - arm); pts[1] := MakePoint(CX + 2, CY);
      pts[2] := MakePoint(CX, CY + arm); pts[3] := MakePoint(CX - 2, CY);
      g.FillPolygon(br, PGPPoint(@pts[0]), 4);                           // vertical flare
      pts[0] := MakePoint(CX - arm, CY); pts[1] := MakePoint(CX, CY - 2);
      pts[2] := MakePoint(CX + arm, CY); pts[3] := MakePoint(CX, CY + 2);
      g.FillPolygon(br, PGPPoint(@pts[0]), 4);                           // horizontal flare
      g.FillEllipse(br, CX - rad div 2, CY - rad div 2, rad, rad);       // core
    finally
      br.Free;
    end;
  finally
    g.Free;
  end;
end;

procedure TfrmProjectStart.tmrShineTimer(Sender: TObject);
var r: TRect;
begin
  FShinePhase := FShinePhase + 0.11;
  r := Rect(0, 0, ClientWidth, HEADER_HEIGHT);
  InvalidateRect(Handle, @r, False);
end;

procedure TfrmProjectStart.Prepare(const AVersionText: string; const ARecent: TArray<string>;
  AShowOnStartup: Boolean);
var
  i: Integer;
  btn: TGLButton;
begin
  lblVersion.Caption := AVersionText;
  chkShowOnStartup.Checked := AShowOnStartup;
  for i := 0 to PROJECT_START_RECENT_COUNT - 1 do
  begin
    btn := FindComponent('btnRecent' + IntToStr(i)) as TGLButton;
    if i < Length(ARecent) then FRecent[i] := ARecent[i] else FRecent[i] := '';
    btn.Enabled := FRecent[i] <> '';
    if FRecent[i] <> '' then
    begin
      btn.Caption := ChangeFileExt(ExtractFileName(FRecent[i]), '');   // no extension: keeps the name inside the button
      btn.Hint := FRecent[i];
    end
    else
    begin
      btn.Caption := '-';
      btn.Hint := '';
    end;
  end;
end;

function TfrmProjectStart.GetShowOnStartup: Boolean;
begin
  Result := chkShowOnStartup.Checked;
end;

procedure TfrmProjectStart.Choose(AChoice: TProjectStartChoice);
begin
  FChoice := AChoice;
  if AChoice = pscNone then ModalResult := mrCancel else ModalResult := mrOk;
end;

procedure TfrmProjectStart.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then Choose(pscNone);
end;

procedure TfrmProjectStart.btnNewClick(Sender: TObject);
begin
  Choose(pscNew);
end;

procedure TfrmProjectStart.btnOpenClick(Sender: TObject);
begin
  Choose(pscOpen);
end;

procedure TfrmProjectStart.btnHelpClick(Sender: TObject);
begin
  Choose(pscHelp);
end;

procedure TfrmProjectStart.btnAboutClick(Sender: TObject);
begin
  Choose(pscAbout);
end;

procedure TfrmProjectStart.btnRecentClick(Sender: TObject);
var idx: Integer;
begin
  idx := (Sender as TComponent).Tag;
  if (idx < 0) or (idx >= PROJECT_START_RECENT_COUNT) or (FRecent[idx] = '') then Exit;
  FRecentPath := FRecent[idx];
  Choose(pscRecent);
end;

{ the close icon is painted straight onto the header (a ring with a cross, nothing behind it), so
  only the ring-x itself is ever visible; it lights up under the pointer }
function TfrmProjectStart.CloseRect: TRect;
begin
  Result := Rect(ClientWidth - 56, 20, ClientWidth - 24, 52);
end;

procedure TfrmProjectStart.InvalidateClose;
var r: TRect;
begin
  r := CloseRect;
  InvalidateRect(Handle, @r, False);
end;

procedure TfrmProjectStart.SetCloseHot(AValue: Boolean);
begin
  if FCloseHot = AValue then Exit;
  FCloseHot := AValue;
  InvalidateClose;
end;

procedure TfrmProjectStart.PaintCloseIcon;
var
  g: TGPGraphics;
  pen: TGPPen;
  c: TColor;
  r: TRect;
  cx, cy, rad, arm: Single;
begin
  r := CloseRect;
  if FCloseDown and FCloseHot then c := ColorToRGB(StyleServices.GetSystemColor(clHighlight))
  else if FCloseHot then c := MixColor(ColorToRGB(StyleServices.GetSystemColor(clBtnText)),
    ColorToRGB(StyleServices.GetSystemColor(clHighlight)), 0.7)
  else c := MixColor(ColorToRGB(pnlBody.Color), ColorToRGB(StyleServices.GetSystemColor(clBtnText)), 0.75);
  cx := (r.Left + r.Right) / 2;
  cy := (r.Top + r.Bottom) / 2;
  rad := 10;
  arm := 4;
  g := TGPGraphics.Create(Canvas.Handle);
  try
    g.SetSmoothingMode(SmoothingModeAntiAlias);
    pen := TGPPen.Create(MakeColor(255, GetRValue(c), GetGValue(c), GetBValue(c)), 2);
    try
      pen.SetStartCap(LineCapRound);
      pen.SetEndCap(LineCapRound);
      g.DrawEllipse(pen, cx - rad, cy - rad, rad * 2, rad * 2);
      g.DrawLine(pen, cx - arm, cy - arm, cx + arm, cy + arm);
      g.DrawLine(pen, cx + arm, cy - arm, cx - arm, cy + arm);
    finally
      pen.Free;
    end;
  finally
    g.Free;
  end;
end;

procedure TfrmProjectStart.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseMove(Shift, X, Y);
  SetCloseHot(PtInRect(CloseRect, Point(X, Y)));
end;

procedure TfrmProjectStart.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button = mbLeft) and PtInRect(CloseRect, Point(X, Y)) then
  begin
    FCloseDown := True;
    InvalidateClose;
  end;
end;

procedure TfrmProjectStart.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var wasDown: Boolean;
begin
  inherited MouseUp(Button, Shift, X, Y);
  wasDown := FCloseDown;
  FCloseDown := False;
  if wasDown and PtInRect(CloseRect, Point(X, Y)) then Choose(pscNone)
  else if wasDown then InvalidateClose;
end;

procedure TfrmProjectStart.WMNCMouseMove(var Msg: TWMNCMouseMove);
begin
  inherited;
  SetCloseHot(False);
end;

procedure TfrmProjectStart.CMMouseLeave(var Msg: TMessage);
begin
  inherited;
  SetCloseHot(False);
end;

var
  GdiToken: ULONG_PTR;
  GdiInput: TGdiplusStartupInput;

initialization
  GdiInput.GdiplusVersion := 1;
  GdiInput.DebugEventCallback := nil;
  GdiInput.SuppressBackgroundThread := False;
  GdiInput.SuppressExternalCodecs := False;
  GdiplusStartup(GdiToken, @GdiInput, nil);

finalization
  GdiplusShutdown(GdiToken);

end.
