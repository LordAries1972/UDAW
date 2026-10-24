unit UDAW.UI.CapsuleProgress;
{$I udaw.inc}

{ UDAW's own progress bar, drawn on the OpenGL 3.3 canvas (TGLCanvas): a capsule - a track and
  a fill with fully rounded ends - with the progress status text in the middle of it.

  The fill carries light diagonal stripes that run along it while the bar is showing, so it
  looks alive even between two progress updates; in marquee style (no known fraction) a
  capsule-shaped segment sweeps back and forth instead. The text is drawn twice - a dark
  shadow, then the light text - so it stays readable over both the fill and the empty track.

  The members mirror the VCL TProgressBar the status bar used (Min, Max, Position, Style,
  MarqueeInterval), plus Text: what the job is doing. With no Text the percentage is shown. }

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Types, System.UITypes, System.Math,
  Vcl.Controls, Vcl.Graphics, Vcl.ComCtrls, Vcl.ExtCtrls,
  UDAW.GL.Canvas, UDAW.GL.Widgets, UDAW.UI.ThemeColors;

type
  TGLCapsuleProgress = class(TGLWidget)
  private
    FMin, FMax, FPosition: Integer;
    FStyle: TProgressBarStyle;
    FMarqueeInterval: Integer;
    FText: string;
    FPhase: Double;            // 0..1 animation phase (stripes / marquee)
    FTimer: TTimer;
    procedure SetMin(AValue: Integer);
    procedure SetMax(AValue: Integer);
    procedure SetPosition(AValue: Integer);
    procedure SetStyle(AValue: TProgressBarStyle);
    procedure SetText(const AValue: string);
    procedure TimerTick(Sender: TObject);
    procedure UpdateTimer;
    function Fraction: Double;
  protected
    procedure PaintGL; override;
    procedure CMVisibleChanged(var Msg: TMessage); message CM_VISIBLECHANGED;
    procedure Loaded; override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property Min: Integer read FMin write SetMin default 0;
    property Max: Integer read FMax write SetMax default 100;
    property Position: Integer read FPosition write SetPosition default 0;
    property Style: TProgressBarStyle read FStyle write SetStyle default pbstNormal;
    { how fast the marquee sweeps: a smaller interval is faster (kept like TProgressBar's) }
    property MarqueeInterval: Integer read FMarqueeInterval write FMarqueeInterval default 30;
    { the progress status text, centred in the capsule }
    property Text: string read FText write SetText;
  end;

implementation

const
  ANIM_MS = 33;            // about 30 frames a second while the bar is showing
  STRIPE_W = 16;           // distance between two stripes, in pixels

function Mix(A, B: TColor; T: Double): TColor;
var
  ca, cb: LongInt;
  ar, ag, ab, br, bg, bb: Byte;
begin
  ca := ColorToRGB(A);
  cb := ColorToRGB(B);
  ar := ca and $FF; ag := (ca shr 8) and $FF; ab := (ca shr 16) and $FF;
  br := cb and $FF; bg := (cb shr 8) and $FF; bb := (cb shr 16) and $FF;
  Result := TColor(Byte(Round(ar + (br - ar) * T)) or
    (Byte(Round(ag + (bg - ag) * T)) shl 8) or
    (Byte(Round(ab + (bb - ab) * T)) shl 16));
end;

constructor TGLCapsuleProgress.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  SharedSurface := True;
  TabStop := False;
  FMin := 0;
  FMax := 100;
  FPosition := 0;
  FStyle := pbstNormal;
  FMarqueeInterval := 30;
  Width := 360;
  Height := 17;
  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := ANIM_MS;
  FTimer.OnTimer := TimerTick;
end;

function TGLCapsuleProgress.Fraction: Double;
begin
  if FMax <= FMin then Exit(0);
  Result := EnsureRange((FPosition - FMin) / (FMax - FMin), 0.0, 1.0);
end;

procedure TGLCapsuleProgress.SetMin(AValue: Integer);
begin
  if FMin = AValue then Exit;
  FMin := AValue;
  Invalidate;
end;

procedure TGLCapsuleProgress.SetMax(AValue: Integer);
begin
  if FMax = AValue then Exit;
  FMax := AValue;
  Invalidate;
end;

procedure TGLCapsuleProgress.SetPosition(AValue: Integer);
begin
  AValue := EnsureRange(AValue, System.Math.Min(FMin, FMax), System.Math.Max(FMin, FMax));
  if FPosition = AValue then Exit;
  FPosition := AValue;
  Invalidate;
end;

procedure TGLCapsuleProgress.SetStyle(AValue: TProgressBarStyle);
begin
  if FStyle = AValue then Exit;
  FStyle := AValue;
  Invalidate;
end;

procedure TGLCapsuleProgress.SetText(const AValue: string);
begin
  if FText = AValue then Exit;
  FText := AValue;
  Invalidate;
end;

{ the animation only runs while the bar is on screen }
procedure TGLCapsuleProgress.UpdateTimer;
begin
  if FTimer <> nil then FTimer.Enabled := Visible and not (csDesigning in ComponentState);
end;

procedure TGLCapsuleProgress.CMVisibleChanged(var Msg: TMessage);
begin
  inherited;
  UpdateTimer;
end;

{ a bar that is already visible when its form is loaded (the splash screen) starts animating at once }
procedure TGLCapsuleProgress.Loaded;
begin
  inherited Loaded;
  UpdateTimer;
end;

procedure TGLCapsuleProgress.TimerTick(Sender: TObject);
var
  step: Double;
begin
  { marquee / stripes: a full cycle takes about 0.6 s at the default interval }
  step := ANIM_MS / (System.Math.Max(10, FMarqueeInterval) * 33.0) * 1.7;
  FPhase := FPhase + step;
  if FPhase >= 1.0 then FPhase := FPhase - 1.0;
  if Visible then Invalidate;
end;

procedure TGLCapsuleProgress.PaintGL;
var
  cv: TGLCanvas;
  th: TUDAWTheme;
  w, h, r, fw, x, segW, segX, tx, ty, k: Integer;
  trackCol, fillCol, hiCol, txt: TColor;
  s: string;
  f, sweep: Double;

  { s shortened with an ellipsis to fit AWidth }
  function Fit(const AText: string; AWidth: Integer): string;
  begin
    Result := AText;
    if cv.TextWidth(Result) <= AWidth then Exit;
    while (Length(Result) > 1) and (cv.TextWidth(Result + '...') > AWidth) do
      Delete(Result, Length(Result), 1);
    Result := Result + '...';
  end;

begin
  cv := GL;
  th := CurrentTheme;
  w := Width;
  h := Height;
  r := h;                       // a radius of the full height makes the ends semicircles
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := th.Background;
  cv.FillRect(Rect(0, 0, w, h));

  trackCol := Mix(th.Background, th.Text, 0.14);
  fillCol := th.Accent;
  hiCol := Mix(th.Accent, clWhite, 0.35);

  { track, set into the surface: shadow along its top, a lip of light along its bottom }
  cv.Brush.Color := trackCol;
  cv.RoundRect(0, 0, w, h, r, r);
  cv.PushClip(Rect(1, 1, w - 1, h - 1));
  try
    cv.Brush.Color := clBlack;
    for k := 0 to 3 do
    begin
      cv.Alpha := 0.16 - k * 0.035;
      cv.RoundRect(0, 0, w, h div 2 + 2 - k, r, r);
    end;
    cv.Brush.Color := clWhite;
    cv.Alpha := 0.16;
    cv.RoundRect(h div 4, h - 3, w - h div 4, h, r, r);
    cv.Alpha := 1;
  finally
    cv.PopClip;
  end;

  if FStyle = pbstMarquee then
  begin
    { a capsule-shaped segment sweeping back and forth along the track }
    segW := System.Math.Max(h * 3, w div 3);
    sweep := 1.0 - Abs(2.0 * FPhase - 1.0);            // 0 -> 1 -> 0 triangle wave
    segX := Round(sweep * (w - segW));
    cv.Brush.Color := fillCol;
    cv.RoundRect(segX, 0, segX + segW, h, r, r);
    cv.Brush.Color := hiCol;
    cv.Alpha := 0.45;
    cv.RoundRect(segX + h div 4, 1, segX + segW - h div 4, h div 2, r, r);
    cv.Alpha := 1;
  end
  else
  begin
    f := Fraction;
    fw := Round(f * w);
    if fw > 0 then
    begin
      fw := System.Math.Max(fw, h);                    // never narrower than a full capsule end
      { the shadow the bar throws onto the track ahead of it (and a little below): stacked, fading
        outlines of the fill, so it is darkest right at the leading edge }
      cv.PushClip(Rect(1, 1, w - 1, h - 1));
      try
        cv.Brush.Color := clBlack;
        for k := 8 downto 1 do
        begin
          cv.Alpha := 0.075;
          cv.RoundRect(0, k div 4, System.Math.Min(w + h, fw + k * 2), h + k div 4, r, r);
        end;
        cv.Alpha := 1;
      finally
        cv.PopClip;
      end;
      cv.Brush.Color := fillCol;
      cv.RoundRect(0, 0, fw, h, r, r);
      { the underside of the bar in shade, so it looks round and stands proud of the track }
      cv.Brush.Color := Mix(fillCol, clBlack, 0.45);
      cv.Alpha := 0.50;
      cv.RoundRect(h div 5, h * 55 div 100, System.Math.Max(h div 5 + 2, fw - h div 5), h - 1, r, r);
      cv.Alpha := 1;
      { a lighter band along the top half: the bar reads as a glossy tube }
      cv.Brush.Color := hiCol;
      cv.Alpha := 0.40;
      cv.RoundRect(h div 4, 1, System.Math.Max(h div 4 + 2, fw - h div 4), h div 2, r, r);
      cv.Alpha := 1;
      { diagonal stripes drifting along the fill; kept clear of the rounded ends }
      if fw > h * 2 then
      begin
        cv.PushClip(Rect(h div 2, 1, fw - h div 2, h - 1));
        try
          cv.Brush.Color := clWhite;
          cv.Alpha := 0.16;
          k := Round(FPhase * STRIPE_W);
          x := -STRIPE_W + k;
          while x < fw do
          begin
            cv.Polygon([Point(x, h), Point(x + STRIPE_W div 2, h),
              Point(x + STRIPE_W div 2 + h, 0), Point(x + h, 0)]);
            Inc(x, STRIPE_W);
          end;
          cv.Alpha := 1;
        finally
          cv.PopClip;
        end;
      end;
    end;
  end;

  { the capsule's 3D boundary: an outer ring that is lit along its top and dark along its bottom
    (a raised frame), and an inner ring the other way round (the trough it holds) }
  cv.Brush.Style := bsClear;
  cv.Pen.Style := psSolid;
  cv.Pen.Color := clWhite;
  cv.Alpha := 0.55;
  cv.RoundRect(0, 0, w, h - 1, r, r);
  cv.Pen.Color := clBlack;
  cv.Alpha := 0.55;
  cv.RoundRect(0, 1, w, h, r, r);
  cv.Alpha := 1;
  cv.Pen.Color := Mix(th.Border, th.Text, 0.25);
  cv.RoundRect(1, 1, w - 1, h - 1, r, r);
  cv.Pen.Color := clBlack;
  cv.Alpha := 0.35;
  cv.RoundRect(2, 2, w - 2, h - 3, r, r);
  cv.Pen.Color := clWhite;
  cv.Alpha := 0.30;
  cv.RoundRect(2, 3, w - 2, h - 2, r, r);
  cv.Alpha := 1;
  cv.Pen.Style := psClear;

  { the status text, in the middle }
  s := FText;
  if (s = '') and (FStyle = pbstNormal) then s := Format('%d%%', [Round(Fraction * 100)]);
  if s <> '' then
  begin
    cv.Font.Size := 8;
    cv.Font.Style := [fsBold];
    s := Fit(s, w - h);
    tx := (w - cv.TextWidth(s)) div 2;
    ty := (h - cv.TextHeight(s)) div 2;
    cv.Brush.Style := bsClear;
    cv.Font.Color := clBlack;
    cv.Alpha := 0.55;
    cv.TextOut(tx + 1, ty + 1, s);                      // shadow
    cv.Alpha := 1;
    txt := clWhite;
    cv.Font.Color := txt;
    cv.TextOut(tx, ty, s);
    cv.Font.Style := [];
  end;
  cv.Brush.Style := bsSolid;
end;

end.
