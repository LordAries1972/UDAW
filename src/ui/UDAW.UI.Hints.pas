{ UDAW.UI.Hints - custom "bubble" hint window used by every control in the
  application.

  Installing this unit (it is in the project's uses list) replaces the VCL's
  yellow rectangle with a rounded, gradient, fading-in bubble showing a title
  (the hovered control's caption, or the first line of the hint when the hint
  text is "Title" + LF + "body") and the hint text word-wrapped underneath.

  Hints are switched on/off system-wide - not per project - with
  SetUDAWHintsEnabled, driven by the Settings > "Show hints" check box which
  is persisted in the application config ([general] show_hints, default on). }
unit UDAW.UI.Hints;

interface

uses
  Windows, Messages, SysUtils, Classes, Graphics, Controls, Forms, ExtCtrls,
  StdCtrls, Types, Math;

type
  TUDAWHintWindow = class(THintWindow)
  private
    FTitle: string;
    FBody: string;
    FAlpha: Integer;
    FFade: TTimer;
    procedure FadeTick(Sender: TObject);
    procedure SplitHint(const AHint: string);
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function CalcHintRect(MaxWidth: Integer; const AHint: string;
      AData: Pointer): TRect; override;
    procedure ActivateHint(Rect: TRect; const AHint: string); override;
  end;

procedure SetUDAWHintsEnabled(AEnabled: Boolean);
function UDAWHintsEnabled: Boolean;

{ Gives every control in AOwner's tree that has hint text an enabled
  ShowHint (independent of its parent), so designer-set hints work without
  each control needing ParentShowHint = False. }
procedure ActivateHintsFor(AOwner: TComponent);

implementation

uses
  UDAW.GL.Widgets;

type
  TCtlAccess = class(TControl);   // Caption/ParentShowHint are protected on TControl

const
  PAD_X = 12;
  PAD_Y = 8;
  ACCENT_W = 4;
  MAX_TEXT_W = 300;

var
  GHintsEnabled: Boolean = True;

procedure SetUDAWHintsEnabled(AEnabled: Boolean);
begin
  GHintsEnabled := AEnabled;
  Application.ShowHint := AEnabled;
  if not AEnabled then
    Application.CancelHint;
end;

function UDAWHintsEnabled: Boolean;
begin
  Result := GHintsEnabled;
end;

procedure ActivateHintsFor(AOwner: TComponent);
var
  i: Integer;
  c: TComponent;
begin
  for i := 0 to AOwner.ComponentCount - 1 do
  begin
    c := AOwner.Components[i];
    if (c is TControl) and (TControl(c).Hint <> '') then
    begin
      TCtlAccess(c).ParentShowHint := False;
      TControl(c).ShowHint := True;
    end;
  end;
end;

{ Title for the control currently under the mouse: its caption without
  accelerator ampersands / trailing colon / ellipsis. }
function HoveredTitle: string;
var
  c: TControl;
begin
  Result := '';
  c := FindVCLWindow(Mouse.CursorPos);
  if c = nil then Exit;
  if c is TGLWidget then
    Result := TGLWidget(c).Caption
  else if (c is TButtonControl) or (c is TCustomLabel) or (c is TCustomStaticText) then
    Result := TCtlAccess(c).Caption;
  Result := StringReplace(Result, '&', '', [rfReplaceAll]);
  Result := Trim(Result);
  while (Result <> '') and CharInSet(Result[Length(Result)], [':', '.']) do
    Delete(Result, Length(Result), 1);
end;

{ TUDAWHintWindow }

constructor TUDAWHintWindow.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FAlpha := 255;
  FFade := TTimer.Create(Self);
  FFade.Enabled := False;
  FFade.Interval := 15;
  FFade.OnTimer := FadeTick;
end;

destructor TUDAWHintWindow.Destroy;
begin
  FFade.Enabled := False;
  inherited;
end;

procedure TUDAWHintWindow.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  Params.Style := Params.Style and not WS_BORDER;
  Params.ExStyle := Params.ExStyle or WS_EX_LAYERED;
end;

procedure TUDAWHintWindow.SplitHint(const AHint: string);
var
  p: Integer;
begin
  p := Pos(#10, AHint);
  if p > 0 then
  begin
    FTitle := Trim(Copy(AHint, 1, p - 1));
    FBody := Trim(Copy(AHint, p + 1, MaxInt));
  end
  else
  begin
    FTitle := HoveredTitle;
    FBody := Trim(AHint);
  end;
end;

function TUDAWHintWindow.CalcHintRect(MaxWidth: Integer; const AHint: string;
  AData: Pointer): TRect;
var
  r: TRect;
  w, h: Integer;
begin
  SplitHint(AHint);
  if MaxWidth > MAX_TEXT_W then MaxWidth := MAX_TEXT_W;
  w := 0;
  h := 0;

  if FTitle <> '' then
  begin
    Canvas.Font.Name := 'Segoe UI';
    Canvas.Font.Size := 9;
    Canvas.Font.Style := [fsBold];
    r := Rect(0, 0, MaxWidth, 0);
    DrawText(Canvas.Handle, PChar(FTitle), -1, r, DT_CALCRECT or DT_SINGLELINE or DT_NOPREFIX);
    w := r.Right;
    h := r.Bottom + 3;
  end;

  Canvas.Font.Style := [];
  Canvas.Font.Size := 9;
  r := Rect(0, 0, MaxWidth, 0);
  DrawText(Canvas.Handle, PChar(FBody), -1, r, DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
  if r.Right > w then w := r.Right;
  h := h + r.Bottom;

  Result := Rect(0, 0, w + PAD_X * 2 + ACCENT_W, h + PAD_Y * 2);
end;

procedure TUDAWHintWindow.ActivateHint(Rect: TRect; const AHint: string);
var
  rgn: HRGN;
  pt: TPoint;
  wa: TRect;
  w, h, x, y: Integer;
begin
  SplitHint(AHint);
  { keep the hint on screen: when it would run off the right or bottom edge it opens the
    other way round the pointer (to its left / above it) instead, then is clamped to the
    monitor's work area so it can always be read }
  pt := Mouse.CursorPos;
  wa := Screen.MonitorFromPoint(pt).WorkareaRect;
  w := Rect.Right - Rect.Left;
  h := Rect.Bottom - Rect.Top;
  x := Rect.Left;
  y := Rect.Top;
  if x + w > wa.Right then x := pt.X - w - 6;
  if y + h > wa.Bottom then y := pt.Y - h - 6;
  x := Max(wa.Left, Min(x, wa.Right - w));
  y := Max(wa.Top, Min(y, wa.Bottom - h));
  Rect := Types.Rect(x, y, x + w, y + h);
  FAlpha := 0;
  FFade.Enabled := False;
  BoundsRect := Rect;
  rgn := CreateRoundRectRgn(0, 0, Width + 1, Height + 1, 14, 14);
  SetWindowRgn(Handle, rgn, True);   // the window owns rgn from here
  SetLayeredWindowAttributes(Handle, 0, 0, LWA_ALPHA);
  SetWindowPos(Handle, HWND_TOPMOST, Left, Top, Width, Height,
    SWP_SHOWWINDOW or SWP_NOACTIVATE);
  Invalidate;
  FFade.Enabled := True;
end;

procedure TUDAWHintWindow.FadeTick(Sender: TObject);
begin
  Inc(FAlpha, 45);
  if FAlpha >= 245 then
  begin
    FAlpha := 245;             // stays a touch translucent
    FFade.Enabled := False;
  end;
  SetLayeredWindowAttributes(Handle, 0, FAlpha, LWA_ALPHA);
end;

procedure TUDAWHintWindow.Paint;
const
  TOP_C: TColor = $003A2A1E;      // BGR: deep blue-slate
  BOT_C: TColor = $00201510;
  ACCENT: TColor = $00F0B040;     // BGR: azure
  TITLE_C: TColor = $00FFE9C8;
  BODY_C: TColor = $00E0D6CC;
var
  y, h, w: Integer;
  t: Double;
  r: TRect;
  function Mix(A, B: TColor; T: Double): TColor;
  begin
    Result := RGB(
      Round(GetRValue(A) + (GetRValue(B) - GetRValue(A)) * T),
      Round(GetGValue(A) + (GetGValue(B) - GetGValue(A)) * T),
      Round(GetBValue(A) + (GetBValue(B) - GetBValue(A)) * T));
  end;
begin
  w := Width;
  h := Height;
  for y := 0 to h - 1 do
  begin
    if h > 1 then t := y / (h - 1) else t := 0;
    Canvas.Pen.Color := Mix(TOP_C, BOT_C, t);
    Canvas.MoveTo(0, y);
    Canvas.LineTo(w, y);
  end;

  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := ACCENT;
  Canvas.FillRect(Rect(0, 0, ACCENT_W, h));

  Canvas.Pen.Color := Mix(ACCENT, BOT_C, 0.55);
  Canvas.Brush.Style := bsClear;
  Canvas.RoundRect(0, 0, w, h, 14, 14);

  Canvas.Brush.Style := bsClear;
  r := Rect(ACCENT_W + PAD_X, PAD_Y, w - PAD_X, h - PAD_Y);
  if FTitle <> '' then
  begin
    Canvas.Font.Name := 'Segoe UI';
    Canvas.Font.Size := 9;
    Canvas.Font.Style := [fsBold];
    Canvas.Font.Color := TITLE_C;
    DrawText(Canvas.Handle, PChar(FTitle), -1, r, DT_SINGLELINE or DT_NOPREFIX);
    Inc(r.Top, Canvas.TextHeight(FTitle) + 3);
  end;
  Canvas.Font.Style := [];
  Canvas.Font.Color := BODY_C;
  DrawText(Canvas.Handle, PChar(FBody), -1, r, DT_WORDBREAK or DT_NOPREFIX);
end;

type
  { every form's designer-set button hints go live the moment that form is
    shown, so secondary windows (Foley, Meters, insert editor, Help...) get
    the same rollover hints as the main window without wiring each one }
  TFormHintActivator = class
    procedure ActiveFormChanged(Sender: TObject);
  end;

procedure TFormHintActivator.ActiveFormChanged(Sender: TObject);
begin
  if Screen.ActiveForm <> nil then ActivateHintsFor(Screen.ActiveForm);
end;

var
  GFormHintActivator: TFormHintActivator;

initialization
  HintWindowClass := TUDAWHintWindow;
  GFormHintActivator := TFormHintActivator.Create;
  Screen.OnActiveFormChange := GFormHintActivator.ActiveFormChanged;
  Application.HintPause := 400;
  Application.HintShortPause := 120;
  Application.HintHidePause := 12000;

end.
