unit UDAW.GL.Menus;

{ GL menus: a menu bar (TGLMenuBar) and drop-down / pop-up menus drawn on the
  shared GL surface. They are driven by the ordinary Delphi menu components, so
  the menus stay designed in the form designer (TMainMenu / TPopupMenu with
  TMenuItem handlers, shortcuts, Visible / Enabled / Checked / RadioItem and
  captions with '&' accelerators); only the drawing and the mouse / keyboard
  handling are done here.

    TGLMenuBar     set Menu to the TMainMenu; Align alTop. The form must not
                   also have Menu assigned (that would show the native bar) and
                   should pass IsShortCut on to the TMainMenu.
    GLShowPopup    shows a TPopupMenu. Every TGLView with a PopupMenu uses it
                   automatically (right click / the menu key).

  While a menu is open the mouse is captured by its first window and a
  thread keyboard hook handles Up / Down / Left / Right / Enter / Esc and the
  accelerator letters. }

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes,
  System.Types, System.UITypes, System.Math, System.Generics.Collections,
  Vcl.Controls, Vcl.Graphics, Vcl.Forms, Vcl.Menus, Vcl.Themes, Vcl.ExtCtrls,
  UDAW.GL.Canvas, UDAW.GL.Widgets, UDAW.GL.Controls;

type
  TGLMenuBar = class;

  { one drop-down / pop-up window listing the visible children of a menu item }
  TGLMenuWindow = class(TGLView)
  private
    FParentItem: TMenuItem;
    FRows: TArray<TMenuItem>;
    FTops: TArray<Integer>;
    FHeights: TArray<Integer>;
    FHot: Integer;
    FMeasure: TBitmap;
    FShortW: Integer;
    FMenuFont: TFont;
    FFade: TTimer;                // drives the fade in / fade out
    FPillTimer: TTimer;           // glides the highlight pill from row to row
    FPillTop, FPillBot: Double;   // the pill as drawn now
    FPillGoalTop, FPillGoalBot: Double;
    FPillAlpha, FPillGoalAlpha: Double;
    FPillPhase: Double;           // advances all the time the pill is showing: drives the shimmer and the glow pulse
    FAlpha: Integer;              // 0..FADE_MAX, the window's opacity
    FFadingOut: Boolean;
    procedure PillTick(Sender: TObject);
    procedure Build;
    procedure FadeTick(Sender: TObject);
    procedure WMMouseActivate(var Msg: TWMMouseActivate); message WM_MOUSEACTIVATE;
    procedure WMCaptureChanged(var Msg: TMessage); message WM_CAPTURECHANGED;
    procedure WMCaptureLost(var Msg: TMessage); message WM_APP + 21;
    procedure CMRelease(var Msg: TMessage); message CM_RELEASE;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure CreateWnd; override;
    procedure PaintGL; override;
    procedure PrepareCanvas(ACanvas: TGLCanvas); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor CreateFor(AItem: TMenuItem);
    destructor Destroy; override;
    procedure FadeIn;
    function ItemAtScreen(const P: TPoint): Integer;
    function RowItem(AIndex: Integer): TMenuItem;
    function RowCount: Integer;
    function RowTopOnScreen(AIndex: Integer): Integer;
    function Selectable(AIndex: Integer): Boolean;
    function HasChildren(AIndex: Integer): Boolean;
    procedure SetHot(AIndex: Integer);
    property Hot: Integer read FHot;
    { hides the window and frees it once the current message is done }
    procedure Dismiss;
  end;

  { the strip across the top of the form }
  TGLMenuBar = class(TGLWidget)
  private
    FMenu: TMainMenu;
    FOpen: Integer;
    FHover: Integer;
    FRects: TArray<TRect>;
    FItems: TArray<TMenuItem>;
    FMeasure: TBitmap;
    FStatusText: string;
    FOutText: string;
    FOutRect: TRect;
    FOutHover: Boolean;
    FOnOutClick: TNotifyEvent;
    FCloseRect: TRect;
    FCloseHover: Boolean;
    FOnCloseClick: TNotifyEvent;
    procedure SetOutText(const AValue: string);
    procedure SetStatusText(const AValue: string);
    procedure SetMenu(AValue: TMainMenu);
    procedure MenuChanged(Sender: TObject; Source: TMenuItem; Rebuild: Boolean);
    procedure Layout;
    function IndexAt(X, Y: Integer): Integer;
    procedure CMMouseLeave(var Msg: TMessage); message CM_MOUSELEAVE;
    procedure CMDialogChar(var Msg: TCMDialogChar); message CM_DIALOGCHAR;
    procedure WMOpenMenu(var Msg: TMessage); message WM_APP + 22;
  protected
    procedure PaintGL; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure OpenMenu(AIndex: Integer);
    function IndexAtScreen(const P: TPoint): Integer;
    function ScreenRectOfItem(AIndex: Integer): TRect;
    function VisibleCount: Integer;
    function ItemAt(AIndex: Integer): TMenuItem;
    procedure Closed;
    { a read-out window at the bar's far right (the frame-rate display); empty hides it }
    property StatusText: string read FStatusText write SetStatusText;
    { the audio-output field right of the read-out: drawn flat with a drop arrow; a click raises OnOutClick }
    property OutText: string read FOutText write SetOutText;
    property OnOutClick: TNotifyEvent read FOnOutClick write FOnOutClick;
    { the close button in the bar's top right corner; drawn while OnCloseClick is assigned }
    property OnCloseClick: TNotifyEvent read FOnCloseClick write FOnCloseClick;
    function OutRectOnScreen: TRect;
  published
    property Menu: TMainMenu read FMenu write SetMenu;
  end;

{ shows a pop-up menu at screen position X, Y (OnPopup is raised first) }
procedure GLShowPopup(AMenu: TPopupMenu; X, Y: Integer);
{ true while any GL menu is open }
function GLMenuOpen: Boolean;
procedure GLMenuCloseAll;

implementation


uses
  UDAW.DSP.MathTables;

const
  FADE_MAX = 250;           { the menus stay a touch translucent }
  ROW_PAD = 12;
  SEP_H = 11;
  GUTTER = 36;

type
  TGLMouseKind = (mkMove, mkDown, mkUp);

  TGLMenuSession = class
  private
    FWins: TList<TGLMenuWindow>;
    FBar: TGLMenuBar;
    FBarIndex: Integer;
    FDown: Boolean;
    FHook: HHOOK;
    FMouseHook: HHOOK;
    FLastPt: TPoint;
  public
    constructor Create;
    destructor Destroy; override;
    function OwnsWindow(AWnd: HWND): Boolean;
    procedure OpenRoot(AItem: TMenuItem; X, Y: Integer; ABar: TGLMenuBar; ABarIndex: Integer);
    procedure OpenSub(ALevel: Integer; AIndex: Integer; AFocusFirst: Boolean);
    procedure TrimTo(ALevel: Integer);
    procedure CloseAll;
    procedure Mouse(AKind: TGLMouseKind; const P: TPoint);
    function Key(AVk: Word): Boolean;
    function Letter(ACh: Char): Boolean;
    procedure Hover(ALevel, AIndex: Integer);
    procedure Activate(ALevel, AIndex: Integer);
    procedure SwitchBar(AIndex: Integer);
    function Deepest: TGLMenuWindow;
  end;

var
  GSession: TGLMenuSession;

function MenuFace: TColor;
begin
  Result := ColorToRGB(StyleServices.GetSystemColor(clBtnFace));
end;

function MenuInk: TColor;
begin
  Result := ColorToRGB(StyleServices.GetSystemColor(clBtnText));
end;

function MixColor(A, B: TColor; T: Double): TColor;
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

{ caption as shown: '&&' -> '&', accelerator marks removed }
function ShownCap(const S: string): string;
begin
  Result := StringReplace(S, '&&', #1, [rfReplaceAll]);
  Result := StringReplace(Result, '&', '', [rfReplaceAll]);
  Result := StringReplace(Result, #1, '&', [rfReplaceAll]);
end;

{ the accelerator letter of a caption ('&File' -> 'F'), or #0 }
function AccelOf(const S: string): Char;
var
  i: Integer;
begin
  Result := #0;
  i := 1;
  while i < Length(S) do
  begin
    if S[i] = '&' then
    begin
      if S[i + 1] = '&' then Inc(i)
      else Exit(UpCase(S[i + 1]));
    end;
    Inc(i);
  end;
end;

function ItemIsSep(AItem: TMenuItem): Boolean;
begin
  Result := AItem.Caption = '-';
end;

function ItemShown(AItem: TMenuItem): Boolean; forward;

{ how many entries of a menu will really be listed (separators do not count) }
function VisibleKids(AItem: TMenuItem): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to AItem.Count - 1 do
    if (not ItemIsSep(AItem.Items[i])) and ItemShown(AItem.Items[i]) then Inc(Result);
end;

{ A menu lists only what can be used right now: a disabled command is left out (it comes back by itself
  the next time the menu opens and the command is valid again - menus are built fresh on every open),
  and so is a submenu that has nothing usable in it.  A submenu whose own OnClick fills or enables its
  entries is kept, since it can only do that once it is opened.  Separators are tidied by the caller. }
function ItemShown(AItem: TMenuItem): Boolean;
begin
  Result := AItem.Visible;
  if (not Result) or ItemIsSep(AItem) then Exit;
  if not AItem.Enabled then Exit(False);
  if (AItem.Count > 0) and (not Assigned(AItem.OnClick)) and (VisibleKids(AItem) = 0) then Exit(False);
end;

function KeyHookProc(ACode: Integer; AWParam: WPARAM; ALParam: LPARAM): LRESULT; stdcall;
begin
  if (ACode >= 0) and (GSession <> nil) and (ALParam and $80000000 = 0) then
  begin
    if GSession.Key(Word(AWParam)) then Exit(1);
  end;
  Result := CallNextHookEx(0, ACode, AWParam, ALParam);
end;

{ A button press anywhere but on the open menu (or its bar) closes it. Normally the first menu
  window holds the mouse capture and sees the click itself; this covers the cases where the
  capture was taken away (a timer, a drag, another control) and the click would otherwise
  fall through to the control underneath with the menu left hanging open. The click is not
  swallowed, so it still reaches whatever was clicked. }
var
  GSwallowHook: HHOOK;

{ A click that only closes a menu must do nothing else: the press is swallowed by the hook
  below and the button release that follows is swallowed here, so neither reaches the control
  that happened to be under the pointer. Removes itself after that one release. }
function SwallowHookProc(ACode: Integer; AWParam: WPARAM; ALParam: LPARAM): LRESULT; stdcall;
var
  h: HHOOK;
begin
  h := GSwallowHook;
  if ACode >= 0 then
    case AWParam of
      WM_LBUTTONUP, WM_RBUTTONUP, WM_MBUTTONUP,
      WM_NCLBUTTONUP, WM_NCRBUTTONUP, WM_NCMBUTTONUP:
        begin
          GSwallowHook := 0;
          UnhookWindowsHookEx(h);
          Exit(1);
        end;
      WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN,
      WM_NCLBUTTONDOWN, WM_NCRBUTTONDOWN, WM_NCMBUTTONDOWN:
        begin
          { a fresh press without the release having been seen: stop swallowing }
          GSwallowHook := 0;
          UnhookWindowsHookEx(h);
        end;
    end;
  Result := CallNextHookEx(0, ACode, AWParam, ALParam);
end;

procedure SwallowNextRelease;
begin
  if GSwallowHook = 0 then
    GSwallowHook := SetWindowsHookEx(WH_MOUSE, @SwallowHookProc, 0, GetCurrentThreadId);
end;

function MouseHookProc(ACode: Integer; AWParam: WPARAM; ALParam: LPARAM): LRESULT; stdcall;
var
  wnd: HWND;
begin
  if (ACode >= 0) and (GSession <> nil) then
    case AWParam of
      WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN,
      WM_NCLBUTTONDOWN, WM_NCRBUTTONDOWN, WM_NCMBUTTONDOWN:
        begin
          wnd := PMouseHookStruct(ALParam)^.hwnd;
          if not GSession.OwnsWindow(wnd) then
          begin
            GSession.CloseAll;       // frees the session and this hook
            SwallowNextRelease;
            Exit(1);                 // the press only closes the menu
          end;
        end;
    end;
  Result := CallNextHookEx(0, ACode, AWParam, ALParam);
end;

{ TGLMenuWindow }

constructor TGLMenuWindow.CreateFor(AItem: TMenuItem);
begin
  inherited Create(nil);
  SharedSurface := True;
  { the session owns the mouse capture; the VCL must not release it on button up }
  ControlStyle := ControlStyle + [csOpaque] - [csCaptureMouse];
  FParentItem := AItem;
  FHot := -1;
  FMeasure := TBitmap.Create;
  FMeasure.SetSize(8, 8);
  FMenuFont := TFont.Create;
  FMenuFont.Assign(Screen.MenuFont);
  FFade := TTimer.Create(Self);
  FFade.Enabled := False;
  FFade.Interval := 15;
  FFade.OnTimer := FadeTick;
  FPillTimer := TTimer.Create(Self);
  FPillTimer.Enabled := False;
  FPillTimer.Interval := 15;
  FPillTimer.OnTimer := PillTick;
  Build;
end;

destructor TGLMenuWindow.Destroy;
begin
  FMenuFont.Free;
  FMeasure.Free;
  inherited Destroy;
end;

procedure TGLMenuWindow.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  Params.Style := (Params.Style and not WS_CHILD) or WS_POPUP;
  Params.ExStyle := Params.ExStyle or WS_EX_TOOLWINDOW or WS_EX_TOPMOST or WS_EX_NOACTIVATE or WS_EX_LAYERED;
  Params.WndParent := GetDesktopWindow;
end;

procedure TGLMenuWindow.WMMouseActivate(var Msg: TWMMouseActivate);
begin
  Msg.Result := MA_NOACTIVATE;
end;

procedure TGLMenuWindow.WMCaptureChanged(var Msg: TMessage);
begin
  inherited;
  { mouse capture taken by another window (e.g. a click elsewhere): close }
  if (GSession <> nil) and (GSession.FWins.Count > 0) and (GSession.FWins[0] = Self) and
     (HWND(Msg.LParam) <> Handle) then
    PostMessage(Handle, WM_APP + 21, 0, 0);
end;

{ the capture was taken by something else (a click in another window): close,
  unless this window is no longer the session's first one }
procedure TGLMenuWindow.WMCaptureLost(var Msg: TMessage);
begin
  if (GSession <> nil) and (GSession.FWins.Count > 0) and (GSession.FWins[0] = Self) and
     (GetCapture <> Handle) then
    GSession.CloseAll;
end;

procedure TGLMenuWindow.CMRelease(var Msg: TMessage);
begin
  Free;
end;

procedure TGLMenuWindow.Dismiss;
begin
  { a menu that is on screen fades out (and lets mouse clicks fall through to what is under it) instead of vanishing }
  if HandleAllocated and IsWindowVisible(Handle) and (FAlpha > 0) and not FFadingOut then
  begin
    FFadingOut := True;
    SetWindowLong(Handle, GWL_EXSTYLE, GetWindowLong(Handle, GWL_EXSTYLE) or WS_EX_TRANSPARENT);
    FFade.Enabled := True;
    Exit;
  end;
  if HandleAllocated then
  begin
    ShowWindow(Handle, SW_HIDE);
    PostMessage(Handle, CM_RELEASE, 0, 0);
  end
  else Free;
end;

procedure TGLMenuWindow.Build;
var
  i, n, y, w, tw: Integer;
  it: TMenuItem;
  cnt: Integer;
  shown: TArray<TMenuItem>;
begin
  FMeasure.Canvas.Font.Assign(FMenuFont);
  { the entries to list; no separator first, last or twice in a row }
  SetLength(shown, 0);
  for i := 0 to FParentItem.Count - 1 do
  begin
    it := FParentItem.Items[i];
    if not ItemShown(it) then Continue;
    if ItemIsSep(it) and ((Length(shown) = 0) or ItemIsSep(shown[High(shown)])) then Continue;
    shown := shown + [it];
  end;
  while (Length(shown) > 0) and ItemIsSep(shown[High(shown)]) do SetLength(shown, Length(shown) - 1);
  cnt := Length(shown);
  SetLength(FRows, cnt);
  SetLength(FTops, cnt);
  SetLength(FHeights, cnt);
  n := 0;
  y := 6;
  w := 120;
  FShortW := 0;
  for i := 0 to cnt - 1 do
  begin
    it := shown[i];
    FRows[n] := it;
    FTops[n] := y;
    if ItemIsSep(it) then FHeights[n] := SEP_H
    else
    begin
      FHeights[n] := FMeasure.Canvas.TextHeight('Ag') + ROW_PAD;
      tw := FMeasure.Canvas.TextWidth(ShownCap(it.Caption));
      if it.ShortCut <> 0 then
        FShortW := System.Math.Max(FShortW, FMeasure.Canvas.TextWidth(ShortCutToText(it.ShortCut)));
      w := System.Math.Max(w, tw);
    end;
    Inc(y, FHeights[n]);
    Inc(n);
  end;
  Inc(y, 6);
  { gutter + text + gap + shortcut key cap + arrow }
  w := GUTTER + 6 + w + 28 + 18;
  if FShortW > 0 then Inc(w, FShortW + 26);
  Width := w;
  Height := y;
end;

function TGLMenuWindow.RowCount: Integer;
begin
  Result := Length(FRows);
end;

function TGLMenuWindow.RowItem(AIndex: Integer): TMenuItem;
begin
  if (AIndex >= 0) and (AIndex < Length(FRows)) then Result := FRows[AIndex] else Result := nil;
end;

function TGLMenuWindow.RowTopOnScreen(AIndex: Integer): Integer;
begin
  Result := ClientToScreen(Point(0, FTops[AIndex])).Y;
end;

function TGLMenuWindow.Selectable(AIndex: Integer): Boolean;
begin
  Result := (AIndex >= 0) and (AIndex < Length(FRows)) and not ItemIsSep(FRows[AIndex]) and
    FRows[AIndex].Enabled;
end;

function TGLMenuWindow.HasChildren(AIndex: Integer): Boolean;
begin
  Result := (AIndex >= 0) and (AIndex < Length(FRows)) and (VisibleKids(FRows[AIndex]) > 0);
end;

procedure TGLMenuWindow.SetHot(AIndex: Integer);
begin
  if FHot = AIndex then Exit;
  FHot := AIndex;
  { the highlight pill glides to the new row (or fades away when no enabled row is hot) }
  if (AIndex >= 0) and (AIndex < Length(FRows)) and FRows[AIndex].Enabled and not ItemIsSep(FRows[AIndex]) then
  begin
    FPillGoalTop := FTops[AIndex] + 1;
    FPillGoalBot := FTops[AIndex] + FHeights[AIndex] - 1;
    if FPillAlpha < 0.05 then
    begin
      FPillTop := FPillGoalTop;
      FPillBot := FPillGoalBot;
    end;
    FPillGoalAlpha := 1;
  end
  else
    FPillGoalAlpha := 0;
  FPillTimer.Enabled := True;
  Invalidate;
end;

procedure TGLMenuWindow.PillTick(Sender: TObject);
var
  moving: Boolean;
begin
  FPillTop := FPillTop + (FPillGoalTop - FPillTop) * 0.45;
  FPillBot := FPillBot + (FPillGoalBot - FPillBot) * 0.45;
  if Abs(FPillGoalTop - FPillTop) < 0.5 then FPillTop := FPillGoalTop;
  if Abs(FPillGoalBot - FPillBot) < 0.5 then FPillBot := FPillGoalBot;
  if FPillAlpha < FPillGoalAlpha then FPillAlpha := System.Math.Min(FPillGoalAlpha, FPillAlpha + 0.25)
  else if FPillAlpha > FPillGoalAlpha then FPillAlpha := System.Math.Max(FPillGoalAlpha, FPillAlpha - 0.2);
  moving := (FPillTop <> FPillGoalTop) or (FPillBot <> FPillGoalBot) or (FPillAlpha <> FPillGoalAlpha);
  FPillPhase := FPillPhase + 0.11;
  { keeps running while a row is lit so the highlight itself stays alive }
  if (not moving) and (FPillGoalAlpha = 0) then FPillTimer.Enabled := False;
  Invalidate;
end;

function TGLMenuWindow.ItemAtScreen(const P: TPoint): Integer;
var
  c: TPoint;
  i: Integer;
begin
  Result := -1;
  c := ScreenToClient(P);
  for i := 0 to High(FRows) do
    if (c.Y >= FTops[i]) and (c.Y < FTops[i] + FHeights[i]) and (c.X >= 0) and (c.X < Width) then
      Exit(i);
end;

procedure TGLMenuWindow.PrepareCanvas(ACanvas: TGLCanvas);
begin
  inherited PrepareCanvas(ACanvas);
  ACanvas.Font.Name := FMenuFont.Name;
  ACanvas.Font.Height := FMenuFont.Height;
end;

{ the icon a menu item shows in its gutter, chosen from its caption (the menus are designed in the
  form designer without images, so the commands everybody knows get a matching vector icon) }
function IconIdFor(const ACaption: string): string;
const
  MAP: array[0..37, 0..1] of string = (
    ('save as', 'saveas'), ('save', 'save'), ('open', 'open'), ('new', 'new'),
    ('export', 'export'), ('import', 'add'), ('undo', 'undo'), ('redo', 'redo'),
    ('cut', 'cut'), ('copy', 'clone'), ('paste', 'paste'), ('delete', 'trash'),
    ('remove', 'trash'), ('erase', 'erase'), ('add', 'add'), ('play', 'play'),
    ('stop', 'stop'), ('record', 'record'), ('loop', 'loop'), ('zoom in', 'zoomin'),
    ('zoom out', 'zoomout'), ('split', 'split'), ('select', 'select'), ('range', 'range'),
    ('reverse', 'left'), ('previous', 'left'), ('next', 'right'), ('help', 'help'),
    ('about', 'help'), ('mixer', 'mixer'), ('piano', 'piano'), ('tracker', 'tracker'),
    ('video', 'video'), ('settings', 'tools'), ('tools', 'tools'), ('rename', 'tools'),
    ('duplicate', 'clone'), ('browser', 'browser'));
var
  cap: string;
  i: Integer;
begin
  Result := '';
  cap := LowerCase(ShownCap(ACaption));
  for i := 0 to High(MAP) do
    if Pos(MAP[i, 0], cap) > 0 then Exit(MAP[i, 1]);
end;

{ the icon shown left of a menu bar title, chosen from the title }
function BarIconIdFor(const ACaption: string): string;
const
  MAP: array[0..21, 0..1] of string = (
    ('project', 'open'), ('tracker', 'tracker'), ('mixer', 'mixer'), ('midi', 'piano'),
    ('timeline', 'lanes'), ('mp3', 'export'), ('system', 'browser'), ('log', 'editor'),
    ('jobs', 'loop'), ('audio', 'mute'), ('dsp', 'fx'), ('graph', 'stage'),
    ('supported sfx', 'wavedit'), ('recording', 'record'), ('secure storage', 'save'),
    ('mp4', 'video'), ('settings', 'tools'), ('scope', 'zoomsel'), ('advanced dsp', 'euclid'),
    ('ai', 'ai'), ('scripts', 'chords'), ('help', 'help'));
var
  cap: string;
  i: Integer;
begin
  Result := '';
  cap := LowerCase(Trim(ShownCap(ACaption)));
  for i := 0 to High(MAP) do
    if MAP[i, 0] = cap then Exit(MAP[i, 1]);
end;

procedure TGLMenuWindow.CreateWnd;
var
  rgn: HRGN;
begin
  inherited CreateWnd;
  { rounded corners }
  rgn := CreateRoundRectRgn(0, 0, Width + 1, Height + 1, 12, 12);
  SetWindowRgn(Handle, rgn, True);   // the window owns rgn from here
  { fully opaque until the session asks it to fade in (FadeIn) - a menu must never stay invisible }
  FAlpha := FADE_MAX;
  SetLayeredWindowAttributes(Handle, 0, FADE_MAX, LWA_ALPHA);
end;

{ starts the fade-in: transparent now, fully shown a tenth of a second later. Called by the session just before the window is shown. }
procedure TGLMenuWindow.FadeIn;
begin
  HandleNeeded;
  FFadingOut := False;
  FAlpha := 0;
  SetLayeredWindowAttributes(Handle, 0, 0, LWA_ALPHA);
  FFade.Enabled := True;
end;

{ about a seventh of a second in, a little quicker out }
procedure TGLMenuWindow.FadeTick(Sender: TObject);
begin
  if FFadingOut then
  begin
    Dec(FAlpha, 46);
    if FAlpha <= 0 then
    begin
      FAlpha := 0;
      FFade.Enabled := False;
      ShowWindow(Handle, SW_HIDE);
      PostMessage(Handle, CM_RELEASE, 0, 0);
      Exit;
    end;
  end
  else
  begin
    Inc(FAlpha, 38);
    if FAlpha >= FADE_MAX then
    begin
      FAlpha := FADE_MAX;
      FFade.Enabled := False;
    end;
  end;
  SetLayeredWindowAttributes(Handle, 0, Byte(FAlpha), LWA_ALPHA);
end;

procedure TGLMenuWindow.PaintGL;
var
  cv: TGLCanvas;
  face, faceTop, ink, accent, accentDeep, grey, dimInk, edge: TColor;
  i, th, cy, tx, y, mid, kw, iy: Integer;
  it: TMenuItem;
  hot: Boolean;
  pulse, sweep: Double;
  sx, k: Integer;
  txtColor: TColor;
  sc, icon: string;
  r: TRect;
begin
  if (FAlpha = 0) and not FFade.Enabled and not FFadingOut then
  begin
    FAlpha := FADE_MAX;   { safety net }
    SetLayeredWindowAttributes(Handle, 0, FADE_MAX, LWA_ALPHA);
  end;
  cv := GL;
  face := MixColor(MenuFace, ColorToRGB(StyleServices.GetSystemColor(clWindow)), 0.55);
  ink := MenuInk;
  accent := ColorToRGB(StyleServices.GetSystemColor(clHighlight));
  accentDeep := MixColor(accent, clBlack, 0.35);
  faceTop := MixColor(face, ink, 0.07);
  dimInk := MixColor(face, ink, 0.55);
  grey := MixColor(face, ink, 0.40);
  edge := MixColor(face, accent, 0.55);
  th := cv.TextHeight('Ag');
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  { body: a soft vertical gradient }
  y := 0;
  while y < Height do
  begin
    cv.Brush.Color := MixColor(faceTop, face, EnsureRange(y / System.Math.Max(1, Height - 1) * 1.6, 0, 1));
    cv.FillRect(Rect(0, y, Width, System.Math.Min(Height, y + 3)));
    Inc(y, 3);
  end;
  { the icon column, a shade apart from the text }
  cv.Brush.Color := MixColor(face, clBlack, 0.12);
  cv.Alpha := 0.55;
  cv.FillRect(Rect(0, 0, GUTTER, Height));
  cv.Alpha := 1;

  { the gliding highlight pill: a rounded accent bar with a lighter band across its top }
  if FPillAlpha > 0.02 then
  begin
    r := Rect(5, Round(FPillTop), Width - 5, Round(FPillBot));
    pulse := 0.5 + 0.5 * FastSin(FPillPhase);
    { a soft halo that breathes around the pill }
    cv.Brush.Color := accent;
    cv.Alpha := (0.10 + 0.16 * pulse) * FPillAlpha;
    cv.RoundRect(r.Left - 2, r.Top - 2, r.Right + 2, r.Bottom + 2, 12, 12);
    cv.Alpha := FPillAlpha;
    cv.Brush.Color := accentDeep;
    cv.RoundRect(r.Left, r.Top, r.Right, r.Bottom, 9, 9);
    cv.Brush.Color := MixColor(accent, clWhite, 0.06 + 0.14 * pulse);
    cv.RoundRect(r.Left, r.Top, r.Right, r.Bottom - 2, 9, 9);
    cv.Brush.Color := clWhite;
    cv.Alpha := 0.14 * FPillAlpha;
    cv.RoundRect(r.Left + 2, r.Top + 1, r.Right - 2, r.Top + (r.Bottom - r.Top) div 2, 7, 7);
    { a slanted band of light that sweeps across the pill, left to right, over and over }
    cv.PushClip(Rect(r.Left + 1, r.Top + 1, r.Right - 1, r.Bottom - 1));
    sweep := Frac(FPillPhase / 8.0);
    sx := r.Left - 40 + Round(sweep * (r.Right - r.Left + 80));
    cv.Brush.Color := clWhite;
    for k := 0 to 3 do
    begin
      cv.Alpha := (0.05 + 0.05 * k) * FPillAlpha;
      cv.Polygon([Point(sx + k * 5 + 8, r.Top), Point(sx + 30 - k * 5 + 8, r.Top), Point(sx + 30 - k * 5 - 4, r.Bottom), Point(sx + k * 5 - 4, r.Bottom)]);
    end;
    cv.PopClip;
    cv.Alpha := 1;
  end;

  for i := 0 to High(FRows) do
  begin
    it := FRows[i];
    if ItemIsSep(it) then
    begin
      mid := FTops[i] + FHeights[i] div 2;
      cv.Brush.Color := MixColor(face, ink, 0.22);
      cv.FillRect(Rect(GUTTER + 6, mid, Width - 10, mid + 1));
      cv.Brush.Color := MixColor(face, clBlack, 0.35);
      cv.Alpha := 0.5;
      cv.FillRect(Rect(GUTTER + 6, mid + 1, Width - 10, mid + 2));
      cv.Alpha := 1;
      Continue;
    end;
    hot := (i = FHot) and it.Enabled;
    r := Rect(5, FTops[i] + 1, Width - 5, FTops[i] + FHeights[i] - 1);
    if hot then
    begin
      txtColor := ColorToRGB(StyleServices.GetSystemColor(clHighlightText));
    end
    else if it.Enabled then txtColor := ink
    else txtColor := grey;

    cy := FTops[i] + (FHeights[i] - th) div 2;
    cv.Font.Color := txtColor;
    cv.Brush.Style := bsClear;
    cv.TextOut(GUTTER + 6, cy, ShownCap(it.Caption));
    cv.Brush.Style := bsSolid;

    { gutter: the item's icon, or the check / radio mark }
    icon := IconIdFor(it.Caption);
    iy := FTops[i] + FHeights[i] div 2;
    if it.Checked then
    begin
      { a ticked item sits on a small accent tile }
      if not hot then
      begin
        cv.Brush.Color := accent;
        cv.Alpha := 0.30;
        cv.RoundRect(4, iy - 10, GUTTER - 2, iy + 10, 7, 7);
        cv.Alpha := 1;
      end;
      cv.Pen.Style := psSolid;
      cv.Pen.Color := txtColor;
      cv.Pen.Width := 2;
      if it.RadioItem then
      begin
        cv.Brush.Color := txtColor;
        cv.Ellipse(GUTTER div 2 - 4, iy - 4, GUTTER div 2 + 5, iy + 5);
      end
      else
      begin
        cv.MoveTo(GUTTER div 2 - 6, iy);
        cv.LineTo(GUTTER div 2 - 2, iy + 4);
        cv.LineTo(GUTTER div 2 + 6, iy - 5);
      end;
      cv.Pen.Width := 1;
      cv.Pen.Style := psClear;
    end
    else if icon <> '' then
    begin
      if hot then TGLIconBar.DrawIcon(cv, icon, Rect(0, FTops[i], GUTTER, FTops[i] + FHeights[i]), txtColor)
      else if it.Enabled then
        TGLIconBar.DrawIcon(cv, icon, Rect(0, FTops[i], GUTTER, FTops[i] + FHeights[i]), MixColor(ink, accent, 0.55))
      else
        TGLIconBar.DrawIcon(cv, icon, Rect(0, FTops[i], GUTTER, FTops[i] + FHeights[i]), grey);
    end;

    { the shortcut as a small key cap }
    sc := '';
    if it.ShortCut <> 0 then sc := ShortCutToText(it.ShortCut);
    if (sc <> '') and (VisibleKids(it) = 0) then
    begin
      kw := cv.TextWidth(sc);
      if hot then cv.Brush.Color := clWhite else cv.Brush.Color := MixColor(face, ink, 0.45);
      cv.Alpha := 0.20;
      cv.RoundRect(Width - 12 - kw - 8, cy - 2, Width - 10, cy + th + 2, 7, 7);
      cv.Alpha := 1;
      cv.Brush.Style := bsClear;
      if hot then cv.Font.Color := txtColor else cv.Font.Color := dimInk;
      cv.TextOut(Width - 12 - kw - 1, cy, sc);
      cv.Brush.Style := bsSolid;
    end;

    { sub-menu chevron }
    if VisibleKids(it) > 0 then
    begin
      tx := Width - 16;
      cv.Pen.Style := psSolid;
      cv.Pen.Color := txtColor;
      cv.Pen.Width := 2;
      cv.MoveTo(tx, iy - 4);
      cv.LineTo(tx + 4, iy);
      cv.LineTo(tx, iy + 4);
      cv.Pen.Width := 1;
      cv.Pen.Style := psClear;
    end;
  end;

  { a fine rounded outline in the accent colour }
  cv.Pen.Style := psSolid;
  cv.Pen.Color := edge;
  cv.Brush.Style := bsClear;
  cv.RoundRect(0, 0, Width, Height, 12, 12);
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
end;

{ only the first window holds the mouse capture, so it receives every event and
  forwards it, in screen coordinates, to the session }
procedure TGLMenuWindow.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  if GSession <> nil then GSession.Mouse(mkMove, ClientToScreen(Point(X, Y)));
end;

procedure TGLMenuWindow.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if GSession <> nil then GSession.Mouse(mkDown, ClientToScreen(Point(X, Y)));
end;

procedure TGLMenuWindow.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if GSession <> nil then GSession.Mouse(mkUp, ClientToScreen(Point(X, Y)));
end;

{ TGLMenuSession }

constructor TGLMenuSession.Create;
begin
  inherited Create;
  FWins := TList<TGLMenuWindow>.Create;
  FBarIndex := -1;
end;

destructor TGLMenuSession.Destroy;
begin
  if FHook <> 0 then UnhookWindowsHookEx(FHook);
  if FMouseHook <> 0 then UnhookWindowsHookEx(FMouseHook);
  FWins.Free;
  inherited Destroy;
end;

function TGLMenuSession.OwnsWindow(AWnd: HWND): Boolean;
var
  w: TGLMenuWindow;
begin
  Result := (FBar <> nil) and FBar.HandleAllocated and (FBar.Handle = AWnd);
  if Result then Exit;
  for w in FWins do
    if w.HandleAllocated and (w.Handle = AWnd) then Exit(True);
end;

function TGLMenuSession.Deepest: TGLMenuWindow;
begin
  if FWins.Count > 0 then Result := FWins[FWins.Count - 1] else Result := nil;
end;

procedure TGLMenuSession.OpenRoot(AItem: TMenuItem; X, Y: Integer; ABar: TGLMenuBar; ABarIndex: Integer);
var
  w: TGLMenuWindow;
  wa: TRect;
begin
  FBar := ABar;
  FBarIndex := ABarIndex;
  FDown := False;
  w := TGLMenuWindow.CreateFor(AItem);
  wa := Screen.MonitorFromPoint(Point(X, Y)).WorkareaRect;
  if X + w.Width > wa.Right then X := System.Math.Max(wa.Left, wa.Right - w.Width);
  if Y + w.Height > wa.Bottom then
  begin
    { open upwards; IfThen would evaluate ABar.Height even for a context menu (no bar) }
    if ABar <> nil then Y := System.Math.Max(wa.Top, Y - w.Height - ABar.Height)
    else Y := System.Math.Max(wa.Top, Y - w.Height);
  end;
  w.HandleNeeded;
  w.FadeIn;
  SetWindowPos(w.Handle, HWND_TOPMOST, X, Y, w.Width, w.Height, SWP_NOACTIVATE or SWP_SHOWWINDOW);
  RedrawWindow(w.Handle, nil, 0, RDW_INVALIDATE or RDW_UPDATENOW);
  FWins.Add(w);
  SetCapture(w.Handle);
  if FHook = 0 then FHook := SetWindowsHookEx(WH_KEYBOARD, @KeyHookProc, 0, GetCurrentThreadId);
  if FMouseHook = 0 then FMouseHook := SetWindowsHookEx(WH_MOUSE, @MouseHookProc, 0, GetCurrentThreadId);
end;

procedure TGLMenuSession.OpenSub(ALevel, AIndex: Integer; AFocusFirst: Boolean);
var
  parentWin, w: TGLMenuWindow;
  it: TMenuItem;
  x, y, i: Integer;
  wa: TRect;
begin
  TrimTo(ALevel);
  parentWin := FWins[ALevel];
  it := parentWin.RowItem(AIndex);
  if (it = nil) or (VisibleKids(it) = 0) or not it.Enabled then Exit;
  w := TGLMenuWindow.CreateFor(it);
  x := parentWin.ClientToScreen(Point(parentWin.Width - 3, 0)).X;
  y := parentWin.RowTopOnScreen(AIndex) - 4;
  wa := Screen.MonitorFromPoint(Point(x, y)).WorkareaRect;
  if x + w.Width > wa.Right then x := parentWin.ClientToScreen(Point(3, 0)).X - w.Width;
  if y + w.Height > wa.Bottom then y := System.Math.Max(wa.Top, wa.Bottom - w.Height);
  w.HandleNeeded;
  w.FadeIn;
  SetWindowPos(w.Handle, HWND_TOPMOST, x, y, w.Width, w.Height, SWP_NOACTIVATE or SWP_SHOWWINDOW);
  RedrawWindow(w.Handle, nil, 0, RDW_INVALIDATE or RDW_UPDATENOW);
  FWins.Add(w);
  if AFocusFirst then
    for i := 0 to w.RowCount - 1 do
      if w.Selectable(i) then
      begin
        w.SetHot(i);
        Break;
      end;
end;

procedure TGLMenuSession.TrimTo(ALevel: Integer);
var
  w: TGLMenuWindow;
begin
  while FWins.Count > ALevel + 1 do
  begin
    w := FWins[FWins.Count - 1];
    FWins.Delete(FWins.Count - 1);
    w.Dismiss;
  end;
end;

procedure TGLMenuSession.CloseAll;
var
  bar: TGLMenuBar;
  w: TGLMenuWindow;
  first: TGLMenuWindow;
begin
  if FWins.Count = 0 then Exit;
  first := FWins[0];
  if GetCapture = first.Handle then ReleaseCapture;
  if FHook <> 0 then
  begin
    UnhookWindowsHookEx(FHook);
    FHook := 0;
  end;
  if FMouseHook <> 0 then
  begin
    UnhookWindowsHookEx(FMouseHook);
    FMouseHook := 0;
  end;
  bar := FBar;
  FBar := nil;
  while FWins.Count > 0 do
  begin
    w := FWins[FWins.Count - 1];
    FWins.Delete(FWins.Count - 1);
    w.Dismiss;
  end;
  if bar <> nil then bar.Closed;
  { the session object itself is released by the caller of CloseAll via GSession }
  if GSession = Self then GSession := nil;
  Free;
end;

procedure TGLMenuSession.Hover(ALevel, AIndex: Integer);
var
  w: TGLMenuWindow;
begin
  w := FWins[ALevel];
  { already hot with its sub-menu showing (or none to show): nothing to do }
  if (AIndex >= 0) and (w.Hot = AIndex) and w.Selectable(AIndex) then
  begin
    if w.HasChildren(AIndex) then
    begin
      if (FWins.Count > ALevel + 1) and (FWins[ALevel + 1].FParentItem = w.RowItem(AIndex)) then Exit;
    end
    else if FWins.Count = ALevel + 1 then Exit;
  end;
  if not w.Selectable(AIndex) then
  begin
    w.SetHot(-1);
    TrimTo(ALevel);
    Exit;
  end;
  w.SetHot(AIndex);
  TrimTo(ALevel);
  if w.HasChildren(AIndex) then OpenSub(ALevel, AIndex, False);
end;

procedure TGLMenuSession.Activate(ALevel, AIndex: Integer);
var
  w: TGLMenuWindow;
  it: TMenuItem;
begin
  w := FWins[ALevel];
  if not w.Selectable(AIndex) then Exit;
  it := w.RowItem(AIndex);
  if w.HasChildren(AIndex) then
  begin
    OpenSub(ALevel, AIndex, True);
    Exit;
  end;
  CloseAll;      { frees this session }
  it.Click;
end;

procedure TGLMenuSession.SwitchBar(AIndex: Integer);
var
  bar: TGLMenuBar;
  r: TRect;
  it: TMenuItem;
begin
  bar := FBar;
  if (bar = nil) or (AIndex < 0) or (AIndex >= bar.VisibleCount) then Exit;
  it := bar.ItemAt(AIndex);
  if VisibleKids(it) = 0 then Exit;
  TrimTo(0);
  { replace the first window with the new drop-down }
  if FWins.Count > 0 then
  begin
    if GetCapture = FWins[0].Handle then ReleaseCapture;
    FWins[0].Dismiss;
    FWins.Delete(0);
  end;
  r := bar.ScreenRectOfItem(AIndex);
  FBarIndex := AIndex;
  bar.FOpen := AIndex;
  bar.Invalidate;
  OpenRoot(it, r.Left, r.Bottom, bar, AIndex);
end;

procedure TGLMenuSession.Mouse(AKind: TGLMouseKind; const P: TPoint);
var
  i, idx: Integer;
  w: TGLMenuWindow;
  br: TRect;
begin
  if FWins.Count = 0 then Exit;
  if (AKind = mkMove) and (P.X = FLastPt.X) and (P.Y = FLastPt.Y) then Exit;
  FLastPt := P;
  if FBar <> nil then
  begin
    br := FBar.ScreenRectOfItem(-1);
    if PtInRect(br, P) then
    begin
      idx := FBar.IndexAtScreen(P);
      case AKind of
        mkDown:
          if idx = FBarIndex then CloseAll
          else if idx >= 0 then SwitchBar(idx)
          else
          begin
            CloseAll;
            SwallowNextRelease;
          end;
        mkMove:
          if (idx >= 0) and (idx <> FBarIndex) then SwitchBar(idx);
      end;
      Exit;
    end;
  end;
  for i := FWins.Count - 1 downto 0 do
  begin
    w := FWins[i];
    if PtInRect(Rect(w.ClientToScreen(Point(0, 0)).X, w.ClientToScreen(Point(0, 0)).Y,
         w.ClientToScreen(Point(0, 0)).X + w.Width, w.ClientToScreen(Point(0, 0)).Y + w.Height), P) then
    begin
      idx := w.ItemAtScreen(P);
      case AKind of
        mkMove: Hover(i, idx);
        mkDown:
          begin
            FDown := True;
            Hover(i, idx);
          end;
        mkUp:
          if FDown then Activate(i, idx);
      end;
      Exit;
    end;
  end;
  if AKind = mkDown then
  begin
    CloseAll;
    SwallowNextRelease;   // the release must not click whatever is under the pointer
  end;
end;

function TGLMenuSession.Key(AVk: Word): Boolean;
var
  w: TGLMenuWindow;
  lvl, n, i, k, step: Integer;
begin
  Result := False;
  if FWins.Count = 0 then Exit;
  lvl := FWins.Count - 1;
  w := FWins[lvl];
  Result := True;
  case AVk of
    VK_ESCAPE:
      if lvl > 0 then TrimTo(lvl - 1) else CloseAll;
    VK_DOWN, VK_UP:
      begin
        if AVk = VK_DOWN then step := 1 else step := -1;
        n := w.RowCount;
        i := w.Hot;
        if n = 0 then Exit;
        for k := 1 to n do
        begin
          if i < 0 then i := IfThen(step > 0, -1, n);
          i := (i + step + n) mod n;
          if w.Selectable(i) then
          begin
            w.SetHot(i);
            Break;
          end;
        end;
      end;
    VK_HOME, VK_END:
      begin
        n := w.RowCount;
        if AVk = VK_HOME then
          for i := 0 to n - 1 do
          begin
            if w.Selectable(i) then
            begin
              w.SetHot(i);
              Break;
            end;
          end
        else
          for i := n - 1 downto 0 do
            if w.Selectable(i) then
            begin
              w.SetHot(i);
              Break;
            end;
      end;
    VK_RIGHT:
      if w.HasChildren(w.Hot) and w.Selectable(w.Hot) then OpenSub(lvl, w.Hot, True)
      else if (FBar <> nil) and (FBar.VisibleCount > 1) then SwitchBar((FBarIndex + 1) mod FBar.VisibleCount);
    VK_LEFT:
      if lvl > 0 then TrimTo(lvl - 1)
      else if (FBar <> nil) and (FBar.VisibleCount > 1) then
        SwitchBar((FBarIndex - 1 + FBar.VisibleCount) mod FBar.VisibleCount);
    VK_RETURN, VK_SPACE:
      if w.Selectable(w.Hot) then Activate(lvl, w.Hot);
  else
    if (AVk >= Ord('A')) and (AVk <= Ord('Z')) then Result := Letter(Char(AVk))
    else Result := False;
  end;
end;

function TGLMenuSession.Letter(ACh: Char): Boolean;
var
  w: TGLMenuWindow;
  i, found, cnt: Integer;
begin
  Result := False;
  w := Deepest;
  if w = nil then Exit;
  found := -1;
  cnt := 0;
  for i := 0 to w.RowCount - 1 do
    if w.Selectable(i) and (AccelOf(w.RowItem(i).Caption) = UpCase(ACh)) then
    begin
      if found < 0 then found := i;
      Inc(cnt);
    end;
  if found < 0 then Exit;
  Result := True;
  w.SetHot(found);
  if cnt = 1 then Activate(FWins.Count - 1, found);
end;

{ ---- entry points ---- }

procedure GLShowPopup(AMenu: TPopupMenu; X, Y: Integer);
begin
  if AMenu = nil then Exit;
  GLMenuCloseAll;
  if Assigned(AMenu.OnPopup) then AMenu.OnPopup(AMenu);
  if VisibleKids(AMenu.Items) = 0 then Exit;
  GSession := TGLMenuSession.Create;
  GSession.OpenRoot(AMenu.Items, X, Y, nil, -1);
end;

function GLMenuOpen: Boolean;
begin
  Result := GSession <> nil;
end;

procedure GLMenuCloseAll;
begin
  if GSession <> nil then GSession.CloseAll;
end;

procedure ContextPopup(ACtrl: TControl; AMenu: TPopupMenu; X, Y: Integer);
begin
  AMenu.PopupComponent := ACtrl;
  GLShowPopup(AMenu, X, Y);
end;

{ TGLMenuBar }

constructor TGLMenuBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := False;
  FOpen := -1;
  FHover := -1;
  FMeasure := TBitmap.Create;
  FMeasure.SetSize(8, 8);
  Align := alTop;
  Height := 24;
  Width := 400;
end;

destructor TGLMenuBar.Destroy;
begin
  if (FMenu <> nil) then FMenu.OnChange := nil;
  GLMenuCloseAll;
  FMeasure.Free;
  inherited Destroy;
end;

procedure TGLMenuBar.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = FMenu) then FMenu := nil;
end;

procedure TGLMenuBar.SetMenu(AValue: TMainMenu);
begin
  if FMenu = AValue then Exit;
  if FMenu <> nil then FMenu.OnChange := nil;
  FMenu := AValue;
  if FMenu <> nil then
  begin
    FreeNotification(FMenu);
    FMenu.OnChange := MenuChanged;
  end;
  Invalidate;
end;

procedure TGLMenuBar.MenuChanged(Sender: TObject; Source: TMenuItem; Rebuild: Boolean);
begin
  Invalidate;
end;

const
  BAR_ICON_W = 22;   { room taken by a title's icon }

procedure TGLMenuBar.Layout;
var
  i, n, x: Integer;
  it: TMenuItem;
begin
  FMeasure.Canvas.Font.Assign(Font);
  SetLength(FRects, 0);
  SetLength(FItems, 0);
  if FMenu = nil then Exit;
  x := 4;
  for i := 0 to FMenu.Items.Count - 1 do
  begin
    it := FMenu.Items[i];
    { a disabled title is left out; one whose entries are all disabled stays (its entries may only be enabled
      when it opens), and shows nothing when clicked }
    if (not it.Visible) or (not it.Enabled) then Continue;
    n := Length(FItems);
    SetLength(FItems, n + 1);
    SetLength(FRects, n + 1);
    FItems[n] := it;
    FRects[n] := Rect(x, 1, x + FMeasure.Canvas.TextWidth(ShownCap(it.Caption)) + 20 +
      System.Math.IfThen(BarIconIdFor(it.Caption) <> '', BAR_ICON_W, 0), Height - 1);
    x := FRects[n].Right;
  end;
end;

function TGLMenuBar.VisibleCount: Integer;
begin
  Layout;
  Result := Length(FItems);
end;

function TGLMenuBar.ItemAt(AIndex: Integer): TMenuItem;
begin
  Layout;
  if (AIndex >= 0) and (AIndex < Length(FItems)) then Result := FItems[AIndex] else Result := nil;
end;

function TGLMenuBar.IndexAt(X, Y: Integer): Integer;
var
  i: Integer;
begin
  Layout;
  Result := -1;
  for i := 0 to High(FRects) do
    if PtInRect(FRects[i], Point(X, Y)) then Exit(i);
end;

function TGLMenuBar.IndexAtScreen(const P: TPoint): Integer;
var
  c: TPoint;
begin
  c := ScreenToClient(P);
  Result := IndexAt(c.X, c.Y);
end;

{ AIndex = -1: the whole bar }
function TGLMenuBar.ScreenRectOfItem(AIndex: Integer): TRect;
var
  r: TRect;
begin
  Layout;
  if (AIndex >= 0) and (AIndex < Length(FRects)) then r := FRects[AIndex]
  else r := Rect(0, 0, Width, Height);
  Result := Rect(ClientToScreen(r.TopLeft).X, ClientToScreen(r.TopLeft).Y,
    ClientToScreen(r.BottomRight).X, ClientToScreen(r.BottomRight).Y);
end;

procedure TGLMenuBar.Closed;
begin
  FOpen := -1;
  Invalidate;
end;

procedure TGLMenuBar.OpenMenu(AIndex: Integer);
var
  it: TMenuItem;
  r: TRect;
begin
  it := ItemAt(AIndex);
  if (it = nil) or (VisibleKids(it) = 0) then Exit;
  GLMenuCloseAll;
  r := ScreenRectOfItem(AIndex);
  FOpen := AIndex;
  Invalidate;
  GSession := TGLMenuSession.Create;
  GSession.OpenRoot(it, r.Left, r.Bottom, Self, AIndex);
end;

procedure TGLMenuBar.CMMouseLeave(var Msg: TMessage);
begin
  inherited;
  if FCloseHover then
  begin
    FCloseHover := False;
    Invalidate;
  end;
  if FOutHover then
  begin
    FOutHover := False;
    Invalidate;
  end;
  if FHover <> -1 then
  begin
    FHover := -1;
    Invalidate;
  end;
end;

procedure TGLMenuBar.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  i: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if Assigned(FOnCloseClick) and (PtInRect(FCloseRect, Point(X, Y)) <> FCloseHover) then
  begin
    FCloseHover := not FCloseHover;
    Invalidate;
  end;
  if (FOutText <> '') <> False then
    if PtInRect(FOutRect, Point(X, Y)) <> FOutHover then
    begin
      FOutHover := not FOutHover;
      Invalidate;
    end;
  i := IndexAt(X, Y);
  if i <> FHover then
  begin
    FHover := i;
    Invalidate;
  end;
end;

procedure TGLMenuBar.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  i: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button <> mbLeft) or not Enabled then Exit;
  if Assigned(FOnCloseClick) and PtInRect(FCloseRect, Point(X, Y)) then
  begin
    if MouseCapture then MouseCapture := False;
    FOnCloseClick(Self);
    Exit;
  end;
  if (FOutText <> '') and PtInRect(FOutRect, Point(X, Y)) then
  begin
    if MouseCapture then MouseCapture := False;
    if Assigned(FOnOutClick) then FOnOutClick(Self);
    Exit;
  end;
  i := IndexAt(X, Y);
  if i >= 0 then PostMessage(Handle, WM_APP + 22, i, 0);
end;

procedure TGLMenuBar.WMOpenMenu(var Msg: TMessage);
begin
  if MouseCapture then MouseCapture := False;
  OpenMenu(Msg.WParam);
end;

procedure TGLMenuBar.CMDialogChar(var Msg: TCMDialogChar);
var
  i: Integer;
begin
  Layout;
  if (Msg.KeyData and $20000000 <> 0) and Enabled then
    for i := 0 to High(FItems) do
      if (AccelOf(FItems[i].Caption) = UpCase(Char(Msg.CharCode))) and FItems[i].Enabled then
      begin
        OpenMenu(i);
        if GSession <> nil then GSession.Key(VK_DOWN);
        Msg.Result := 1;
        Exit;
      end;
  inherited;
end;

procedure TGLMenuBar.SetOutText(const AValue: string);
begin
  if FOutText = AValue then Exit;
  FOutText := AValue;
  Invalidate;
end;

function TGLMenuBar.OutRectOnScreen: TRect;
begin
  Result.TopLeft := ClientToScreen(FOutRect.TopLeft);
  Result.BottomRight := ClientToScreen(FOutRect.BottomRight);
end;

procedure TGLMenuBar.SetStatusText(const AValue: string);
begin
  if FStatusText = AValue then Exit;
  FStatusText := AValue;
  Invalidate;
end;

procedure TGLMenuBar.PaintGL;
var
  cv: TGLCanvas;
  face, ink, accent: TColor;
  i, y, bw, bx, by, bh, fSize, closeW, cx, cy: Integer;
  cap, icon, fName: string;
  fStyle: TFontStyles;
begin
  Layout;
  cv := GL;
  face := FaceColor;
  ink := InkColor;
  accent := ColorToRGB(StyleServices.GetSystemColor(clHighlight));
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  { the bar: a soft gradient, lighter at the top }
  y := 0;
  while y < Height do
  begin
    cv.Brush.Color := MixColor(MixColor(face, ink, 0.09), face, y / System.Math.Max(1, Height - 1));
    cv.FillRect(Rect(0, y, Width, System.Math.Min(Height, y + 2)));
    Inc(y, 2);
  end;
  for i := 0 to High(FRects) do
  begin
    { no box or border behind a title, whether hovered or open: the open one is lit yellow }
    cap := ShownCap(FItems[i].Caption);
    if i = FOpen then cv.Font.Color := TColor($0000D7FF)   { yellow }
    else if FItems[i].Enabled then cv.Font.Color := ink
    else cv.Font.Color := MixColor(face, ink, 0.45);
    cv.Brush.Style := bsClear;
    icon := BarIconIdFor(FItems[i].Caption);
    if icon <> '' then
    begin
      cv.Brush.Style := bsSolid;
      cv.Pen.Style := psClear;
      cv.Brush.Color := cv.Font.Color;
      { centred in the bar above its 2 px accent line }
      TGLIconBar.DrawIcon(cv, icon, Rect(FRects[i].Left + 6, 0, FRects[i].Left + 6 + BAR_ICON_W - 2,
        Height - 2), cv.Font.Color);
      cv.Brush.Style := bsClear;
    end;
    cv.TextOut(FRects[i].Left + 10 + System.Math.IfThen(icon <> '', BAR_ICON_W, 0),
      (Height - 2 - cv.TextHeight(cap)) div 2, cap);
    cv.Brush.Style := bsSolid;
  end;
  { the close button: an X in the top right corner, red when hovered }
  FCloseRect := Rect(0, 0, 0, 0);
  closeW := 0;
  if Assigned(FOnCloseClick) then
  begin
    closeW := 34;
    FCloseRect := Rect(Width - closeW, 0, Width, Height - 2);
    if FCloseHover then
    begin
      cv.Brush.Style := bsSolid;
      cv.Pen.Style := psClear;
      cv.Brush.Color := TColor($002B2BC8);
      cv.FillRect(FCloseRect);
    end;
    cv.Pen.Style := psSolid;
    cv.Pen.Width := 2;
    if FCloseHover then cv.Pen.Color := clWhite else cv.Pen.Color := ink;
    cx := FCloseRect.Left + closeW div 2;
    cy := (Height - 2) div 2;
    cv.MoveTo(cx - 5, cy - 5);
    cv.LineTo(cx + 5, cy + 5);
    cv.MoveTo(cx + 5, cy - 5);
    cv.LineTo(cx - 5, cy + 5);
    cv.Pen.Width := 1;
    cv.Pen.Style := psClear;
  end;
  { the read-out window: a lowered bevel box drawn straight onto the bar, so its rounded corners
    show the bar's gradient and not a filled rectangle }
  FOutRect := Rect(0, 0, 0, 0);
  if (FStatusText <> '') or (FOutText <> '') then
  begin
    fName := cv.Font.Name;
    fSize := cv.Font.Size;
    fStyle := cv.Font.Style;
    cv.Font.Name := 'Consolas';
    cv.Font.Size := 10;
    cv.Font.Style := [fsBold];
    bx := Width - 8 - closeW;
    by := 2;
    bh := Height - 2 - 2 * by;
    { the audio output: a flat (no shadow) drop-down field at the far right }
    if FOutText <> '' then
    begin
      bw := cv.TextWidth(FOutText) + 20 + 16;
      bx := bx - bw;
      FOutRect := Rect(bx, by, bx + bw, by + bh);
      cv.Brush.Style := bsSolid;
      cv.Pen.Style := psSolid;
      cv.Pen.Color := MixColor(face, ink, IfThen(FOutHover, 0.5, 0.25));
      cv.Brush.Color := MixColor(MixColor(face, ink, 0.09), face, IfThen(FOutHover, 0.2, 0.5));
      cv.RoundRect(bx, by, bx + bw, by + bh, 8, 8);
      cv.Pen.Style := psClear;
      cv.Brush.Style := bsClear;
      cv.Font.Color := ink;
      cv.TextOut(bx + 10, by + (bh - cv.TextHeight(FOutText)) div 2, FOutText);
      cv.Brush.Style := bsSolid;
      cv.Brush.Color := ink;
      cv.Polygon([Point(bx + bw - 15, by + bh div 2 - 2), Point(bx + bw - 7, by + bh div 2 - 2),
        Point(bx + bw - 11, by + bh div 2 + 3)]);
      bx := bx - 6;
    end;
    if FStatusText <> '' then
    begin
      bw := cv.TextWidth(FStatusText) + 20;
      bx := bx - bw;
      DrawBox3D(cv, Rect(bx, by, bx + bw, by + bh),
        MixColor(MixColor(face, ink, 0.09), face, 0.5), False, 8);
      cv.Brush.Style := bsClear;
      cv.Font.Color := ink;
      cv.TextOut(bx + 10, by + (bh - cv.TextHeight(FStatusText)) div 2, FStatusText);
      cv.Brush.Style := bsSolid;
    end;
    cv.Font.Name := fName;
    cv.Font.Size := fSize;
    cv.Font.Style := fStyle;
  end;
  { a thin accent line along the bottom edge: bright in the middle, fading to the sides }
  for i := 0 to Width - 1 do
    if i mod 4 = 0 then
    begin
      cv.Brush.Color := MixColor(MixColor(face, ink, 0.2), accent,
        System.Math.Max(0.0, 1.0 - Abs(i / System.Math.Max(1, Width) - 0.5) * 2.4));
      cv.FillRect(Rect(i, Height - 2, System.Math.Min(Width, i + 4), Height));
    end;
end;

initialization
  GLContextMenuHandler := ContextPopup;

finalization
  GLContextMenuHandler := nil;
  if GSession <> nil then GSession.CloseAll;

end.
