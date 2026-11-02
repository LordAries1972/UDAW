unit UDAW.UI.PluginUI;
{$I udaw.inc}

{ Builds a Python plug-in's window from the description the script sent (see UDAW.Scripting.PyPlugin
  and Plugins\udaw_plugin.py, class UI), out of UDAW's own OpenGL controls.

  * Every control type of the GL widget set can be created (label ... tree) plus "canvas", a surface
    the script draws itself with draw commands (rectangles, lines, curves, gradients, text ...).
  * Any published property of a control can be set by name from the script (snake_case or
    CamelCase, case-insensitive), so nothing the controls offer is out of reach.
  * A control bound to a parameter follows it both ways; others raise events in the script.
  * Pump moves the plug-in's messages (log lines, control updates, finished pictures) into the
    window; call it from a timer while the window is open. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Types, System.UITypes, System.Math,
  System.JSON, System.Rtti, System.TypInfo, System.Generics.Collections, System.StrUtils, Vcl.ComCtrls, Vcl.Controls,
  Vcl.Graphics, Vcl.Forms, Vcl.ExtCtrls, UDAW.GL.Canvas, UDAW.GL.Widgets, UDAW.Scripting.PyPlugin;

type
  TPyMouseEvent = procedure(const AId, AKind: string; X, Y, AButton: Integer) of object;

  { a surface drawn from the script's draw commands }
  TPyCanvasView = class(TGLWidget)
  private
    FCmds: TJSONArray;
    FCtlId: string;
    FMouseOn: Boolean;
    FLastMove: UInt64;
    FOnMouse: TPyMouseEvent;
    procedure Report(const AKind: string; X, Y, AButton: Integer);
  protected
    procedure PaintGL; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure DblClick; override;
  public
    destructor Destroy; override;
    { takes ownership of ACmds }
    procedure SetCommands(ACmds: TJSONArray);
    property CtlId: string read FCtlId write FCtlId;
    property MouseEnabled: Boolean read FMouseOn write FMouseOn;
    property OnMouse: TPyMouseEvent read FOnMouse write FOnMouse;
  end;

  TPyUiBinder = class;

  { one generated control }
  TPyCtl = class
  public
    Id, CType, Param: string;
    Ctl: TControl;
    ParamIdx: Integer;
    NormMapped: Boolean;       // slider on a logarithmic parameter: runs 0..1, mapped through the param
    Fps: Integer;
    DL, DT, DW, DH: Integer;   // the designed bounds, scaled to the window by Rescale
    SizeSet: Boolean;
    Dirty, Pending: Boolean;
    LastReq, PendingSince: UInt64;
    Binder: TPyUiBinder;
    procedure ChangeEv(Sender: TObject);
    procedure ClickEv(Sender: TObject);
    procedure MouseEv(const AId, AKind: string; X, Y, AButton: Integer);
  end;

  TPyUiBinder = class
  private
    FHost: TPyPluginHost;
    FRoot: TWinControl;
    FHolder: TComponent;
    FCtls: TObjectList<TPyCtl>;
    FById: TDictionary<string, TPyCtl>;
    FGuard: Integer;
    FWinW, FWinH: Integer;
    FWinTitle: string;
    FWinColor: TColor;
    FLastTick: UInt64;
    FMsgs: TList<TPyMsg>;
    FOnLog: TProc<string, string>;
    FOnError: TProc<string>;
    FOnParam: TProc<string, Double>;
    procedure Warn(const AText: string);
    function CreateControl(const AType: string): TControl;
    procedure BuildOne(AObj: TJSONObject; AParent: TWinControl);
    function ResolveParent(const ASpec: string; out AParent: TWinControl): Boolean;
    function SetProp(AObj: TObject; const AName: string; AVal: TJSONValue): Boolean;
    procedure SetFont(AObj: TControl; const AName: string; AVal: TJSONValue);
    procedure SetStrings(AStrings: TStrings; AVal: TJSONValue);
    procedure ApplyProps(C: TPyCtl; AProps: TJSONObject);
    procedure SetValue(C: TPyCtl; AVal: TJSONValue);
    procedure Bind(C: TPyCtl);
    procedure PushParam(C: TPyCtl; const P: TPyParam);
    procedure Hook(C: TPyCtl);
    procedure FillTree(ATree: TGLTree; AParent: TGLTreeNode; AArr: TJSONArray);
    procedure ApplyUi(const AJson: string);
    procedure ApplyPaint(const AJson: string);
    function ParamOf(C: TPyCtl; out P: TPyParam): Boolean;
    procedure UserChanged(C: TPyCtl; const AEvent: string);
    function ValueOf(C: TPyCtl; out AText: string): Double;
    procedure SendMouse(const AId, AKind: string; X, Y, AButton: Integer);
  public
    constructor Create(AHost: TPyPluginHost; ARoot: TWinControl);
    destructor Destroy; override;
    { creates the controls described by AHost.UiJson on ARoot; False if there is no description }
    function Build: Boolean;
    procedure Clear;
    { call from a timer; ATick also lets the script's on_timer run (about 20 times a second) }
    procedure Pump(ATick: Boolean);
    { re-reads every bound parameter from the host (after the host was swapped or restored) }
    procedure RefreshParams;
    { moves the binder to another running instance of the same plug-in }
    procedure Rehost(ANewHost: TPyPluginHost);
    { stretches every control with the window: positions and sizes follow the ratio of the window's
      current size to the size the script designed it at }
    procedure Rescale;
    property Host: TPyPluginHost read FHost;
    property WindowWidth: Integer read FWinW;
    property WindowHeight: Integer read FWinH;
    property WindowTitle: string read FWinTitle;
    property WindowColor: TColor read FWinColor;
    property OnLog: TProc<string, string> read FOnLog write FOnLog;
    property OnError: TProc<string> read FOnError write FOnError;
    { the user moved a parameter in the window }
    property OnParam: TProc<string, Double> read FOnParam write FOnParam;
  end;

function PyParseColor(const AText: string; out AColor: TColor): Boolean;

implementation

type
  TControlAccess = class(TControl);

function PyParseColor(const AText: string; out AColor: TColor): Boolean;
var
  r, g, b: Integer;
begin
  if (Length(AText) = 7) and (AText[1] = '#') and
     TryStrToInt('$' + Copy(AText, 2, 2), r) and TryStrToInt('$' + Copy(AText, 4, 2), g) and
     TryStrToInt('$' + Copy(AText, 6, 2), b) then
  begin
    AColor := TColor(r or (g shl 8) or (b shl 16));
    Exit(True);
  end;
  try
    AColor := StringToColor(AText);
    Result := True;
  except
    Result := False;
  end;
end;

function JNum(AArr: TJSONArray; AIndex: Integer): Double;
var
  v: TJSONValue;
begin
  Result := 0;
  if AIndex >= AArr.Count then Exit;
  v := AArr.Items[AIndex];
  if v is TJSONNumber then Result := TJSONNumber(v).AsDouble;
end;

function JInt(AArr: TJSONArray; AIndex: Integer): Integer;
begin
  Result := Round(JNum(AArr, AIndex));
end;

function JColor(AArr: TJSONArray; AIndex: Integer; out AColor: TColor): Boolean;
begin
  Result := False;
  if AIndex >= AArr.Count then Exit;
  if AArr.Items[AIndex] is TJSONString then
    Result := PyParseColor(AArr.Items[AIndex].Value, AColor);
end;

function JStr(AArr: TJSONArray; AIndex: Integer): string;
begin
  Result := '';
  if (AIndex < AArr.Count) and (AArr.Items[AIndex] is TJSONString) then Result := AArr.Items[AIndex].Value;
end;

function JBool(AArr: TJSONArray; AIndex: Integer): Boolean;
var
  b: Boolean;
begin
  Result := False;
  if (AIndex < AArr.Count) and AArr.Items[AIndex].TryGetValue<Boolean>(b) then Result := b;
end;

{ ---------------- TPyCanvasView ---------------- }

destructor TPyCanvasView.Destroy;
begin
  FCmds.Free;
  inherited Destroy;
end;

procedure TPyCanvasView.SetCommands(ACmds: TJSONArray);
begin
  FCmds.Free;
  FCmds := ACmds;
  Invalidate;
end;

procedure TPyCanvasView.Report(const AKind: string; X, Y, AButton: Integer);
begin
  if FMouseOn and Assigned(FOnMouse) then FOnMouse(FCtlId, AKind, X, Y, AButton);
end;

procedure TPyCanvasView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  Report('mouse_down', X, Y, Ord(Button) + 1);
end;

procedure TPyCanvasView.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseMove(Shift, X, Y);
  { about 30 a second is plenty for a script }
  if GetTickCount64 - FLastMove < 33 then Exit;
  FLastMove := GetTickCount64;
  Report('mouse_move', X, Y, IfThen(ssLeft in Shift, 1, IfThen(ssRight in Shift, 2, 0)));
end;

procedure TPyCanvasView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  Report('mouse_up', X, Y, Ord(Button) + 1);
end;

function TPyCanvasView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := inherited DoMouseWheel(Shift, WheelDelta, MousePos);
  if FMouseOn then
  begin
    MousePos := ScreenToClient(MousePos);
    Report('wheel', MousePos.X, MousePos.Y, WheelDelta div 120);
    Result := True;
  end;
end;

procedure TPyCanvasView.DblClick;
var
  p: TPoint;
begin
  inherited DblClick;
  p := ScreenToClient(Mouse.CursorPos);
  Report('double', p.X, p.Y, 1);
end;

procedure TPyCanvasView.PaintGL;
var
  cv: TGLCanvas;
  i, k, depth, n: Integer;
  a, pts: TJSONArray;
  op, s: string;
  c1, c2, tc: TColor;
  has1, has2: Boolean;
  poly: array of TPoint;
  x, y, w, h, tw: Integer;
  dashed: Boolean;
  al: string;

  procedure SetFillStroke(AFillIdx, AStrokeIdx, AWidthIdx: Integer);
  begin
    has1 := JColor(a, AFillIdx, c1);
    has2 := JColor(a, AStrokeIdx, c2);
    if has1 then
    begin
      cv.Brush.Style := bsSolid;
      cv.Brush.Color := c1;
    end
    else
      cv.Brush.Style := bsClear;
    if has2 then
    begin
      cv.Pen.Style := psSolid;
      cv.Pen.Color := c2;
      cv.Pen.Width := Max(1, JInt(a, AWidthIdx));
    end
    else
      cv.Pen.Style := psClear;
  end;

begin
  cv := GL;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := BackdropColor;
  cv.FillRect(Rect(0, 0, Width, Height));
  if FCmds = nil then Exit;
  depth := 0;
  try
    for i := 0 to FCmds.Count - 1 do
    begin
      if not (FCmds.Items[i] is TJSONArray) then Continue;
      a := TJSONArray(FCmds.Items[i]);
      if a.Count = 0 then Continue;
      op := JStr(a, 0);
      if op = 'fr' then
      begin
        if JColor(a, 5, c1) then
        begin
          cv.Brush.Style := bsSolid;
          cv.Pen.Style := psClear;
          cv.Brush.Color := c1;
          x := JInt(a, 1); y := JInt(a, 2);
          cv.FillRect(Rect(x, y, x + JInt(a, 3), y + JInt(a, 4)));
        end;
      end
      else if op = 'sr' then
      begin
        if JColor(a, 5, c1) then
        begin
          cv.Brush.Style := bsClear;
          cv.Pen.Style := psSolid;
          cv.Pen.Color := c1;
          cv.Pen.Width := Max(1, JInt(a, 6));
          x := JInt(a, 1); y := JInt(a, 2);
          cv.Rectangle(x, y, x + JInt(a, 3), y + JInt(a, 4));
        end;
      end
      else if op = 'rr' then
      begin
        SetFillStroke(6, 7, 8);
        x := JInt(a, 1); y := JInt(a, 2);
        cv.RoundRect(x, y, x + JInt(a, 3), y + JInt(a, 4), JInt(a, 5), JInt(a, 5));
      end
      else if op = 'el' then
      begin
        SetFillStroke(5, 6, 7);
        x := JInt(a, 1); y := JInt(a, 2);
        cv.Ellipse(x, y, x + JInt(a, 3), y + JInt(a, 4));
      end
      else if op = 'ln' then
      begin
        if JColor(a, 5, c1) then
        begin
          dashed := JBool(a, 7);
          cv.Pen.Color := c1;
          cv.Pen.Width := Max(1, JInt(a, 6));
          if dashed then cv.Pen.Style := psDash else cv.Pen.Style := psSolid;
          cv.MoveTo(JInt(a, 1), JInt(a, 2));
          cv.LineTo(JInt(a, 3), JInt(a, 4));
          cv.Pen.Style := psSolid;
        end;
      end
      else if (op = 'pl') or (op = 'pg') then
      begin
        if not ((a.Count > 1) and (a.Items[1] is TJSONArray)) then Continue;
        pts := TJSONArray(a.Items[1]);
        n := pts.Count;
        if n < 2 then Continue;
        SetLength(poly, n);
        for k := 0 to n - 1 do
          if pts.Items[k] is TJSONArray then
          begin
            poly[k].X := Round(JNum(TJSONArray(pts.Items[k]), 0));
            poly[k].Y := Round(JNum(TJSONArray(pts.Items[k]), 1));
          end;
        if op = 'pl' then
        begin
          if JColor(a, 2, c1) then
          begin
            cv.Pen.Style := psSolid;
            cv.Pen.Color := c1;
            cv.Pen.Width := Max(1, JInt(a, 3));
            cv.MoveTo(poly[0].X, poly[0].Y);
            for k := 1 to n - 1 do cv.LineTo(poly[k].X, poly[k].Y);
          end;
        end
        else
        begin
          SetFillStroke(2, 3, 4);
          cv.Polygon(poly);
        end;
      end
      else if op = 'gr' then
      begin
        if JColor(a, 5, c1) and JColor(a, 6, c2) then
        begin
          x := JInt(a, 1); y := JInt(a, 2);
          cv.GradientRect(Rect(x, y, x + JInt(a, 3), y + JInt(a, 4)), c1, c2, JBool(a, 7));
        end;
      end
      else if op = 'tx' then
      begin
        s := JStr(a, 3);
        if not JColor(a, 4, tc) then tc := clWhite;
        cv.Font.Color := tc;
        cv.Font.Size := Max(6, JInt(a, 5));
        if JBool(a, 6) then cv.Font.Style := [fsBold] else cv.Font.Style := [];
        cv.Brush.Style := bsClear;
        x := JInt(a, 1); y := JInt(a, 2); w := JInt(a, 8);
        al := JStr(a, 7);
        tw := cv.TextWidth(s);
        if al = 'center' then
        begin
          if w > 0 then x := x + (w - tw) div 2 else x := x - tw div 2;
        end
        else if al = 'right' then
        begin
          if w > 0 then x := x + w - tw else x := x - tw;
        end;
        cv.TextOut(x, y, s);
      end
      else if op = 'alpha' then
        cv.Alpha := EnsureRange(JNum(a, 1), 0, 1)
      else if op = 'clip' then
      begin
        x := JInt(a, 1); y := JInt(a, 2); w := JInt(a, 3); h := JInt(a, 4);
        cv.PushClip(Rect(x, y, x + w, y + h));
        Inc(depth);
      end
      else if op = 'unclip' then
      begin
        if depth > 0 then
        begin
          cv.PopClip;
          Dec(depth);
        end;
      end;
    end;
  finally
    while depth > 0 do
    begin
      cv.PopClip;
      Dec(depth);
    end;
    cv.Alpha := 1.0;
  end;
end;

{ ---------------- TPyCtl ---------------- }

procedure TPyCtl.ChangeEv(Sender: TObject);
begin
  if Binder.FGuard > 0 then Exit;
  Binder.UserChanged(Self, 'change');
end;

procedure TPyCtl.ClickEv(Sender: TObject);
begin
  if Binder.FGuard > 0 then Exit;
  Binder.UserChanged(Self, 'click');
end;

procedure TPyCtl.MouseEv(const AId, AKind: string; X, Y, AButton: Integer);
begin
  Binder.SendMouse(AId, AKind, X, Y, AButton);
end;

{ ---------------- TPyUiBinder ---------------- }

constructor TPyUiBinder.Create(AHost: TPyPluginHost; ARoot: TWinControl);
begin
  inherited Create;
  FHost := AHost;
  FHost.Retain;
  FHost.AttachUi;
  FRoot := ARoot;
  FHolder := TComponent.Create(nil);
  FCtls := TObjectList<TPyCtl>.Create(True);
  FById := TDictionary<string, TPyCtl>.Create;
  FMsgs := TList<TPyMsg>.Create;
  FWinW := 480;
  FWinH := 320;
  FWinColor := clNone;
end;

destructor TPyUiBinder.Destroy;
begin
  Clear;
  FHolder.Free;
  FMsgs.Free;
  FById.Free;
  FCtls.Free;
  FHost.DetachUi;
  FHost.Release;
  inherited Destroy;
end;

procedure TPyUiBinder.Warn(const AText: string);
begin
  if Assigned(FOnLog) then FOnLog('warning', AText);
end;

procedure TPyUiBinder.Clear;
begin
  FCtls.Clear;
  FById.Clear;
  FreeAndNil(FHolder);
  FHolder := TComponent.Create(nil);
end;

procedure TPyUiBinder.Rescale;
var
  sx, sy: Double;
  c: TPyCtl;
begin
  if (FWinW <= 0) or (FWinH <= 0) or (FRoot = nil) then Exit;
  sx := EnsureRange(FRoot.ClientWidth / FWinW, 0.3, 8);
  sy := EnsureRange(FRoot.ClientHeight / FWinH, 0.3, 8);
  for c in FCtls do
  begin
    if (c.Ctl is TGLPage) or (c.Ctl.Align <> alNone) then Continue;
    if c.SizeSet then
      c.Ctl.SetBounds(Round(c.DL * sx), Round(c.DT * sy), Max(4, Round(c.DW * sx)), Max(4, Round(c.DH * sy)))
    else
    begin
      c.Ctl.Left := Round(c.DL * sx);
      c.Ctl.Top := Round(c.DT * sy);
    end;
  end;
end;

procedure TPyUiBinder.Rehost(ANewHost: TPyPluginHost);
begin
  if ANewHost = FHost then Exit;
  ANewHost.Retain;
  ANewHost.AttachUi;
  FHost.DetachUi;
  FHost.Release;
  FHost := ANewHost;
  RefreshParams;
end;

function TPyUiBinder.CreateControl(const AType: string): TControl;
begin
  Result := nil;
  case IndexText(AType, ['label', 'button', 'check', 'knob', 'slider', 'eq_slider', 'meter', 'progress',
    'combo', 'list', 'edit', 'memo', 'group', 'panel', 'recess', 'collapse', 'tabs', 'tab_strip',
    'scroll_bar', 'scroll_box', 'list_view', 'tree', 'bevel', 'shine', 'splitter', 'status',
    'canvas', 'trackbar']) of
    0: Result := TGLLabel.Create(FHolder);
    1: Result := TGLButton.Create(FHolder);
    2: Result := TGLCheck.Create(FHolder);
    3: Result := TGLKnob.Create(FHolder);
    4: Result := TGLSlider.Create(FHolder);
    5: Result := TGLEqSlider.Create(FHolder);
    6, 7:
      begin
        Result := TGLProgress.Create(FHolder);
        { a "meter" is a segmented level meter; a "progress" stays a plain bar }
        TGLProgress(Result).Segmented := IndexText(AType, ['meter']) = 0;
      end;
    8: Result := TGLCombo.Create(FHolder);
    9: Result := TGLList.Create(FHolder);
    10: Result := TGLEdit.Create(FHolder);
    11: Result := TGLMemo.Create(FHolder);
    12: Result := TGLGroup.Create(FHolder);
    13: Result := TGLPanel.Create(FHolder);
    14: Result := TGLRecessPanel.Create(FHolder);
    15: Result := TGLCollapsePanel.Create(FHolder);
    16: Result := TGLPageControl.Create(FHolder);
    17: Result := TGLTabStrip.Create(FHolder);
    18: Result := TGLScrollBar.Create(FHolder);
    19: Result := TGLScrollBox.Create(FHolder);
    20: Result := TGLListView.Create(FHolder);
    21: Result := TGLTree.Create(FHolder);
    22: Result := TGLBevel.Create(FHolder);
    23: Result := TGLShineBar.Create(FHolder);
    24: Result := TGLSplitter.Create(FHolder);
    25: Result := TGLStatusBar.Create(FHolder);
    26: Result := TPyCanvasView.Create(FHolder);
    27: Result := TGLTrackBar.Create(FHolder);
  end;
end;

{ "id" or "id#page" }
function TPyUiBinder.ResolveParent(const ASpec: string; out AParent: TWinControl): Boolean;
var
  baseId: string;
  page, hash: Integer;
  pc: TPyCtl;
begin
  Result := True;
  AParent := FRoot;
  if ASpec = '' then Exit;
  hash := Pos('#', ASpec);
  if hash > 0 then
  begin
    baseId := Copy(ASpec, 1, hash - 1);
    page := StrToIntDef(Copy(ASpec, hash + 1, MaxInt), 0);
  end
  else
  begin
    baseId := ASpec;
    page := -1;
  end;
  if not FById.TryGetValue(baseId, pc) then Exit(False);
  if (pc.Ctl is TGLPageControl) and (page >= 0) then
  begin
    if page >= TGLPageControl(pc.Ctl).PageCount then
    begin
      Warn(Format('control parent "%s": the tab control has no page %d', [ASpec, page]));
      page := TGLPageControl(pc.Ctl).PageCount - 1;
    end;
    AParent := TGLPageControl(pc.Ctl).Pages[Max(0, page)];
  end
  else if pc.Ctl is TWinControl then
    AParent := TWinControl(pc.Ctl)
  else
  begin
    Warn(Format('control parent "%s" cannot hold other controls', [ASpec]));
    AParent := FRoot;
  end;
end;

function TPyUiBinder.Build: Boolean;
var
  root, win: TJSONObject;
  v: TJSONValue;
  arr: TJSONArray;
  done: array of Boolean;
  i, pass, remaining: Integer;
  parent: TWinControl;
  obj: TJSONObject;
  s: string;
  col: TColor;
begin
  Result := False;
  Clear;
  FWinColor := clNone;
  if FHost.UiJson = '' then Exit;
  v := TJSONObject.ParseJSONValue(FHost.UiJson);
  try
    if not (v is TJSONObject) then Exit;
    root := TJSONObject(v);
    win := root.GetValue('window') as TJSONObject;
    if win <> nil then
    begin
      FWinW := EnsureRange(win.GetValue<Integer>('width', 480), 120, 4000);
      FWinH := EnsureRange(win.GetValue<Integer>('height', 320), 60, 3000);
      FWinTitle := win.GetValue<string>('title', '');
      s := win.GetValue<string>('color', '');
      if (s <> '') and PyParseColor(s, col) then FWinColor := col;
    end;
    { the window's own colour first: every panel that follows takes it, so nothing sits on a different tone }
    if (FWinColor <> clNone) and (FRoot is TGLPanel) then TGLPanel(FRoot).Color := FWinColor;
    arr := root.GetValue('controls') as TJSONArray;
    if arr = nil then Exit(True);
    SetLength(done, arr.Count);
    { parents may be declared after their children: sweep until nothing more can be placed }
    for pass := 0 to 8 do
    begin
      remaining := 0;
      for i := 0 to arr.Count - 1 do
      begin
        if done[i] then Continue;
        obj := arr.Items[i] as TJSONObject;
        if ResolveParent(obj.GetValue<string>('parent', ''), parent) then
        begin
          try
            BuildOne(obj, parent);
          except
            on E: Exception do
              Warn(Format('control "%s": %s', [obj.GetValue<string>('id', '?'), E.Message]));
          end;
          done[i] := True;
        end
        else
          Inc(remaining);
      end;
      if remaining = 0 then Break;
    end;
    for i := 0 to arr.Count - 1 do
      if not done[i] then
        Warn(Format('control "%s" was not created: its parent "%s" does not exist',
          [(arr.Items[i] as TJSONObject).GetValue<string>('id', '?'),
           (arr.Items[i] as TJSONObject).GetValue<string>('parent', '')]));
    Result := True;
  finally
    v.Free;
  end;
  Rescale;
  RefreshParams;
end;

procedure TPyUiBinder.BuildOne(AObj: TJSONObject; AParent: TWinControl);
var
  ctype, id: string;
  ctl: TControl;
  c: TPyCtl;
  props: TJSONObject;
  sizeW, sizeH: Integer;
  pages: TJSONArray;
  k: Integer;
  pg: TGLPage;
  cols, rows, row: TJSONArray;
  it: TGLListItem;
  col: TGLColumn;
  j: Integer;
begin
  ctype := AObj.GetValue<string>('type', '');
  id := AObj.GetValue<string>('id', '');
  if FById.ContainsKey(id) then
  begin
    Warn('duplicate control id "' + id + '" ignored');
    Exit;
  end;
  ctl := CreateControl(ctype);
  if ctl = nil then
  begin
    Warn(Format('control "%s": unknown type "%s"', [id, ctype]));
    Exit;
  end;
  c := TPyCtl.Create;
  c.Id := id;
  c.CType := ctype;
  c.Ctl := ctl;
  c.ParamIdx := -1;
  c.Binder := Self;
  FCtls.Add(c);
  FById.Add(id, c);

  ctl.Parent := AParent;
  sizeW := AObj.GetValue<Integer>('w', -1);
  sizeH := AObj.GetValue<Integer>('h', -1);
  if (sizeW >= 0) and (ctl is TGLLabel) then TGLLabel(ctl).AutoSize := False;
  ctl.Left := AObj.GetValue<Integer>('x', 0);
  ctl.Top := AObj.GetValue<Integer>('y', 0);
  if sizeW >= 0 then ctl.Width := sizeW;
  if sizeH >= 0 then ctl.Height := sizeH;

  props := AObj.GetValue('props') as TJSONObject;

  { structure first: pages, columns, rows, items ... }
  if ctl is TGLPageControl then
  begin
    pages := nil;
    if props <> nil then pages := props.GetValue('pages') as TJSONArray;
    if pages <> nil then
      for k := 0 to pages.Count - 1 do
      begin
        pg := TGLPage.Create(FHolder);
        pg.Parent := TGLPageControl(ctl);
        pg.Caption := pages.Items[k].Value;
      end;
  end;
  if (ctl is TGLListView) and (props <> nil) then
  begin
    cols := props.GetValue('columns') as TJSONArray;
    if cols <> nil then
      for k := 0 to cols.Count - 1 do
      begin
        col := TGLColumn(TGLListView(ctl).Columns.Add);
        if cols.Items[k] is TJSONArray then
        begin
          col.Caption := JStr(TJSONArray(cols.Items[k]), 0);
          if TJSONArray(cols.Items[k]).Count > 1 then col.Width := JInt(TJSONArray(cols.Items[k]), 1);
        end
        else
          col.Caption := cols.Items[k].Value;
      end;
    TGLListView(ctl).ViewStyle := vsReport;
    TGLListView(ctl).RowSelect := True;
    rows := props.GetValue('rows') as TJSONArray;
    if rows <> nil then
    begin
      TGLListView(ctl).Items.BeginUpdate;
      try
        for k := 0 to rows.Count - 1 do
          if rows.Items[k] is TJSONArray then
          begin
            row := TJSONArray(rows.Items[k]);
            it := TGLListView(ctl).Items.Add;
            if row.Count > 0 then it.Caption := row.Items[0].Value;
            for j := 1 to row.Count - 1 do it.SubItems.Add(row.Items[j].Value);
          end;
      finally
        TGLListView(ctl).Items.EndUpdate;
      end;
    end;
  end;
  if (ctl is TGLTree) and (props <> nil) and (props.GetValue('nodes') is TJSONArray) then
  begin
    TGLTree(ctl).Items.BeginUpdate;
    try
      FillTree(TGLTree(ctl), nil, props.GetValue('nodes') as TJSONArray);
    finally
      TGLTree(ctl).Items.EndUpdate;
    end;
  end;
  if ctl is TPyCanvasView then
  begin
    TPyCanvasView(ctl).CtlId := id;
    TPyCanvasView(ctl).MouseEnabled := True;
    c.Fps := 30;
    c.Dirty := True;
  end;

  { containers are transparent by default: no bevel, the colour of what they sit on }
  if (ctl is TGLPanel) and not (ctl is TGLRecessPanel) and not (ctl is TGLCollapsePanel) then
  begin
    TGLPanel(ctl).BevelOuter := bvNone;
    if AParent is TGLPanel then TGLPanel(ctl).Color := TGLPanel(AParent).Color;
  end;

  if props <> nil then ApplyProps(c, props);

  if AObj.GetValue<string>('param', '') <> '' then
  begin
    c.Param := AObj.GetValue<string>('param', '');
    Bind(c);
  end;
  Hook(c);
  c.SizeSet := (sizeW >= 0) and (sizeH >= 0);
  c.DL := ctl.Left;
  c.DT := ctl.Top;
  c.DW := ctl.Width;
  c.DH := ctl.Height;
  if (ctl is TGLKnob) and (AObj.GetValue<string>('label', '') <> '') then
    TGLKnob(ctl).Caption := AObj.GetValue<string>('label', '');
  { a still-unnamed knob takes its parameter's name }
  if (ctl is TGLKnob) and (TGLKnob(ctl).Caption = '') and (c.ParamIdx >= 0) then
    TGLKnob(ctl).Caption := FHost.GetParam(c.ParamIdx).Name;
end;

procedure TPyUiBinder.FillTree(ATree: TGLTree; AParent: TGLTreeNode; AArr: TJSONArray);
var
  i: Integer;
  nd: TGLTreeNode;
  item: TJSONValue;
begin
  for i := 0 to AArr.Count - 1 do
  begin
    item := AArr.Items[i];
    if item is TJSONArray then
    begin
      { ["name", [children...]] }
      if (TJSONArray(item).Count > 0) then
      begin
        nd := ATree.Items.AddChild(AParent, TJSONArray(item).Items[0].Value);
        if (TJSONArray(item).Count > 1) and (TJSONArray(item).Items[1] is TJSONArray) then
          FillTree(ATree, nd, TJSONArray(TJSONArray(item).Items[1]));
      end;
    end
    else
      ATree.Items.AddChild(AParent, item.Value);
  end;
end;

procedure TPyUiBinder.SetStrings(AStrings: TStrings; AVal: TJSONValue);
var
  i: Integer;
begin
  AStrings.BeginUpdate;
  try
    AStrings.Clear;
    if AVal is TJSONArray then
      for i := 0 to TJSONArray(AVal).Count - 1 do AStrings.Add(TJSONArray(AVal).Items[i].Value)
    else
      AStrings.Text := AVal.Value;
  finally
    AStrings.EndUpdate;
  end;
end;

procedure TPyUiBinder.SetFont(AObj: TControl; const AName: string; AVal: TJSONValue);
var
  acc: TControlAccess;
  col: TColor;
  d: Double;
  b: Boolean;
begin
  acc := TControlAccess(AObj);
  acc.ParentFont := False;
  if SameText(AName, 'font_size') then
  begin
    if AVal.TryGetValue<Double>(d) then acc.Font.Size := Round(d);
  end
  else if SameText(AName, 'font_color') then
  begin
    if PyParseColor(AVal.Value, col) then acc.Font.Color := col;
  end
  else if SameText(AName, 'font_name') then
    acc.Font.Name := AVal.Value
  else if SameText(AName, 'bold') then
  begin
    if AVal.TryGetValue<Boolean>(b) then
      if b then acc.Font.Style := acc.Font.Style + [fsBold] else acc.Font.Style := acc.Font.Style - [fsBold];
  end
  else if SameText(AName, 'italic') then
    if AVal.TryGetValue<Boolean>(b) then
      if b then acc.Font.Style := acc.Font.Style + [fsItalic] else acc.Font.Style := acc.Font.Style - [fsItalic];
end;

{ Sets the published property AName (any spelling: read_only / ReadOnly / readonly) from JSON. }
function TPyUiBinder.SetProp(AObj: TObject; const AName: string; AVal: TJSONValue): Boolean;
var
  ctx: TRttiContext;
  prop, p: TRttiProperty;
  want: string;
  d: Double;
  b: Boolean;
  col: TColor;
  ord_: Integer;
  cur: TObject;
begin
  Result := False;
  want := LowerCase(StringReplace(AName, '_', '', [rfReplaceAll]));
  prop := nil;
  ctx := TRttiContext.Create;
  try
    for p in ctx.GetType(AObj.ClassType).GetProperties do
      if (LowerCase(p.Name) = want) and p.IsWritable then
      begin
        prop := p;
        Break;
      end;
    if prop = nil then
    begin
      { a read-only property that is a TStrings can still be filled }
      for p in ctx.GetType(AObj.ClassType).GetProperties do
        if (LowerCase(p.Name) = want) and (p.PropertyType.TypeKind = tkClass) then
        begin
          cur := p.GetValue(AObj).AsObject;
          if cur is TStrings then
          begin
            SetStrings(TStrings(cur), AVal);
            Exit(True);
          end;
        end;
      Exit;
    end;
    case prop.PropertyType.TypeKind of
      tkInteger, tkInt64:
        begin
          if AVal.TryGetValue<Double>(d) then
            prop.SetValue(AObj, TValue.FromOrdinal(prop.PropertyType.Handle, Round(d)))
          else if PyParseColor(AVal.Value, col) then
            prop.SetValue(AObj, TValue.FromOrdinal(prop.PropertyType.Handle, col))
          else
            Exit;
        end;
      tkEnumeration:
        begin
          if prop.PropertyType.Handle = TypeInfo(Boolean) then
          begin
            if AVal.TryGetValue<Boolean>(b) then
              prop.SetValue(AObj, TValue.From<Boolean>(b))
            else
              Exit;
          end
          else
          begin
            ord_ := GetEnumValue(prop.PropertyType.Handle, AVal.Value);
            if ord_ < 0 then Exit;
            prop.SetValue(AObj, TValue.FromOrdinal(prop.PropertyType.Handle, ord_));
          end;
        end;
      tkFloat:
        if AVal.TryGetValue<Double>(d) then prop.SetValue(AObj, TValue.From<Double>(d)) else Exit;
      tkUString, tkString, tkLString, tkWString:
        prop.SetValue(AObj, TValue.From<string>(AVal.Value));
      tkClass:
        begin
          cur := prop.GetValue(AObj).AsObject;
          if cur is TStrings then SetStrings(TStrings(cur), AVal) else Exit;
        end;
    else
      Exit;
    end;
    Result := True;
  finally
    ctx.Free;
  end;
end;

procedure TPyUiBinder.ApplyProps(C: TPyCtl; AProps: TJSONObject);
var
  pair: TJSONPair;
  key: string;
  num: Double;
  al: string;
begin
  Inc(FGuard);
  try
    for pair in AProps do
    begin
      key := LowerCase(pair.JsonString.Value);
      if (key = 'pages') or (key = 'columns') or (key = 'rows') or (key = 'nodes') then Continue;
      if key = 'fps' then
      begin
        if pair.JsonValue.TryGetValue<Double>(num) then C.Fps := EnsureRange(Round(num), 0, 60);
        Continue;
      end;
      if key = 'mouse' then
      begin
        if C.Ctl is TPyCanvasView then pair.JsonValue.TryGetValue<Boolean>(TPyCanvasView(C.Ctl).FMouseOn);
        Continue;
      end;
      if key = 'value' then
      begin
        SetValue(C, pair.JsonValue);
        Continue;
      end;
      if (key = 'font_size') or (key = 'font_color') or (key = 'font_name') or (key = 'bold') or
         (key = 'italic') then
      begin
        SetFont(C.Ctl, key, pair.JsonValue);
        Continue;
      end;
      if (key = 'align') and (C.Ctl is TGLLabel) then
      begin
        al := LowerCase(pair.JsonValue.Value);
        if al = 'center' then TGLLabel(C.Ctl).Alignment := taCenter
        else if al = 'right' then TGLLabel(C.Ctl).Alignment := taRightJustify
        else TGLLabel(C.Ctl).Alignment := taLeftJustify;
        Continue;
      end;
      if (key = 'visible') and (pair.JsonValue is TJSONBool) then
      begin
        C.Ctl.Visible := TJSONBool(pair.JsonValue).AsBoolean;
        Continue;
      end;
      if not SetProp(C.Ctl, pair.JsonString.Value, pair.JsonValue) then
        Warn(Format('control "%s" (%s) has no settable property "%s" of that kind',
          [C.Id, C.CType, pair.JsonString.Value]));
    end;
  finally
    Dec(FGuard);
  end;
end;

procedure TPyUiBinder.SetValue(C: TPyCtl; AVal: TJSONValue);
var
  d: Double;
  b: Boolean;
  ctl: TControl;
begin
  ctl := C.Ctl;
  Inc(FGuard);
  try
    if ctl is TGLValueWidget then
    begin
      if AVal.TryGetValue<Double>(d) then TGLValueWidget(ctl).Position := d;
    end
    else if ctl is TGLProgress then
    begin
      if AVal.TryGetValue<Double>(d) then TGLProgress(ctl).Position := d;
    end
    else if ctl is TGLCombo then
    begin
      if AVal.TryGetValue<Double>(d) then TGLCombo(ctl).ItemIndex := Round(d);
    end
    else if ctl is TGLList then
    begin
      if AVal.TryGetValue<Double>(d) then TGLList(ctl).ItemIndex := Round(d);
    end
    else if ctl is TGLListView then
    begin
      if AVal.TryGetValue<Double>(d) then TGLListView(ctl).ItemIndex := Round(d);
    end
    else if ctl is TGLCheck then
    begin
      if AVal.TryGetValue<Boolean>(b) then TGLCheck(ctl).Checked := b
      else if AVal.TryGetValue<Double>(d) then TGLCheck(ctl).Checked := d >= 0.5;
    end
    else if ctl is TGLButton then
    begin
      if AVal.TryGetValue<Boolean>(b) then TGLButton(ctl).Down := b
      else if AVal.TryGetValue<Double>(d) then TGLButton(ctl).Down := d >= 0.5;
    end
    else if ctl is TGLEdit then
      TGLEdit(ctl).Text := AVal.Value
    else if ctl is TGLMemo then
      TGLMemo(ctl).Text := AVal.Value
    else if ctl is TGLTabStrip then
    begin
      if AVal.TryGetValue<Double>(d) then TGLTabStrip(ctl).TabIndex := Round(d);
    end
    else if ctl is TGLPageControl then
    begin
      if AVal.TryGetValue<Double>(d) then TGLPageControl(ctl).ActivePageIndex := Round(d);
    end
    else if ctl is TGLScrollBar then
    begin
      if AVal.TryGetValue<Double>(d) then TGLScrollBar(ctl).Position := Round(d);
    end
    else if ctl is TGLLabel then
      TGLLabel(ctl).Caption := AVal.Value
    else
      Warn(Format('control "%s" (%s) has no value to set', [C.Id, C.CType]));
  finally
    Dec(FGuard);
  end;
end;

function TPyUiBinder.ParamOf(C: TPyCtl; out P: TPyParam): Boolean;
begin
  Result := (C.ParamIdx >= 0) and (C.ParamIdx < FHost.ParamCount);
  if Result then P := FHost.GetParam(C.ParamIdx);
end;

{ the control follows parameter C.Param: range, resolution and current value }
procedure TPyUiBinder.Bind(C: TPyCtl);
var
  i, j: Integer;
  p: TPyParam;
begin
  C.ParamIdx := -1;
  for i := 0 to FHost.ParamCount - 1 do
    if SameText(FHost.GetParam(i).Id, C.Param) then
    begin
      C.ParamIdx := i;
      Break;
    end;
  if C.ParamIdx < 0 then
  begin
    Warn(Format('control "%s" is bound to unknown parameter "%s"', [C.Id, C.Param]));
    Exit;
  end;
  p := FHost.GetParam(C.ParamIdx);
  Inc(FGuard);
  try
    if C.Ctl is TGLValueWidget then
    begin
      if p.Log and not (C.Ctl is TGLKnob) then
      begin
        C.NormMapped := True;
        TGLValueWidget(C.Ctl).Min := 0;
        TGLValueWidget(C.Ctl).Max := 1;
        TGLValueWidget(C.Ctl).Decimals := 2;
      end
      else
      begin
        TGLValueWidget(C.Ctl).Min := p.Min;
        TGLValueWidget(C.Ctl).Max := p.Max;
        TGLValueWidget(C.Ctl).DefaultPosition := p.DefaultValue;
        TGLValueWidget(C.Ctl).Decimals := p.Decimals;
        if p.Kind in [ppInt, ppBool, ppChoice] then TGLValueWidget(C.Ctl).Step := 1
        else if p.Step > 0 then TGLValueWidget(C.Ctl).Step := p.Step;
        if (C.Ctl is TGLKnob) then TGLKnob(C.Ctl).Logarithmic := p.Log;
      end;
    end
    else if C.Ctl is TGLProgress then
    begin
      TGLProgress(C.Ctl).Min := p.Min;
      TGLProgress(C.Ctl).Max := p.Max;
    end
    else if (C.Ctl is TGLCombo) and (p.Kind = ppChoice) then
    begin
      TGLCombo(C.Ctl).Items.Clear;
      for j := 0 to High(p.Choices) do TGLCombo(C.Ctl).Items.Add(p.Choices[j]);
    end
    else if (C.Ctl is TGLTabStrip) and (p.Kind = ppChoice) then
    begin
      TGLTabStrip(C.Ctl).Tabs := string.Join(';', p.Choices);
    end;
  finally
    Dec(FGuard);
  end;
  PushParam(C, p);
end;

procedure TPyUiBinder.PushParam(C: TPyCtl; const P: TPyParam);
begin
  Inc(FGuard);
  try
    if C.Ctl is TGLValueWidget then
    begin
      if C.NormMapped then TGLValueWidget(C.Ctl).Position := P.ToNorm(P.Value)
      else TGLValueWidget(C.Ctl).Position := P.Value;
    end
    else if C.Ctl is TGLProgress then TGLProgress(C.Ctl).Position := P.Value
    else if C.Ctl is TGLCombo then TGLCombo(C.Ctl).ItemIndex := Round(P.Value)
    else if C.Ctl is TGLCheck then TGLCheck(C.Ctl).Checked := P.Value >= 0.5
    else if C.Ctl is TGLButton then TGLButton(C.Ctl).Down := P.Value >= 0.5
    else if C.Ctl is TGLTabStrip then TGLTabStrip(C.Ctl).TabIndex := Round(P.Value)
    else if C.Ctl is TGLScrollBar then TGLScrollBar(C.Ctl).Position := Round(P.Value);
  finally
    Dec(FGuard);
  end;
end;

procedure TPyUiBinder.RefreshParams;
var
  c: TPyCtl;
  p: TPyParam;
begin
  for c in FCtls do
    if ParamOf(c, p) then PushParam(c, p);
end;

procedure TPyUiBinder.Hook(C: TPyCtl);
begin
  if C.Ctl is TGLValueWidget then TGLValueWidget(C.Ctl).OnChange := C.ChangeEv
  else if C.Ctl is TGLButton then
  begin
    if TGLButton(C.Ctl).Toggle then TGLButton(C.Ctl).OnChange := C.ChangeEv
    else TGLButton(C.Ctl).OnClick := C.ClickEv;
  end
  else if C.Ctl is TGLCheck then TGLCheck(C.Ctl).OnChange := C.ChangeEv
  else if C.Ctl is TGLCombo then TGLCombo(C.Ctl).OnChange := C.ChangeEv
  else if C.Ctl is TGLEdit then TGLEdit(C.Ctl).OnChange := C.ChangeEv
  else if C.Ctl is TGLMemo then TGLMemo(C.Ctl).OnChange := C.ChangeEv
  else if C.Ctl is TGLTabStrip then TGLTabStrip(C.Ctl).OnChange := C.ChangeEv
  else if C.Ctl is TGLPageControl then TGLPageControl(C.Ctl).OnChange := C.ChangeEv
  else if C.Ctl is TGLScrollBar then TGLScrollBar(C.Ctl).OnChange := C.ChangeEv
  else if C.Ctl is TGLList then TGLList(C.Ctl).OnClick := C.ClickEv
  else if C.Ctl is TGLListView then TGLListView(C.Ctl).OnClick := C.ClickEv
  else if C.Ctl is TGLTree then TGLTree(C.Ctl).OnClick := C.ClickEv
  else if C.Ctl is TPyCanvasView then TPyCanvasView(C.Ctl).OnMouse := C.MouseEv;
end;

{ the control's current value as a number (for parameters) and as text (for events) }
function TPyUiBinder.ValueOf(C: TPyCtl; out AText: string): Double;
var
  nd: TGLTreeNode;
begin
  Result := 0;
  AText := '';
  if C.Ctl is TGLValueWidget then Result := TGLValueWidget(C.Ctl).Position
  else if C.Ctl is TGLCombo then
  begin
    Result := TGLCombo(C.Ctl).ItemIndex;
    AText := TGLCombo(C.Ctl).Text;
  end
  else if C.Ctl is TGLCheck then Result := Ord(TGLCheck(C.Ctl).Checked)
  else if C.Ctl is TGLButton then Result := Ord(TGLButton(C.Ctl).Down)
  else if C.Ctl is TGLEdit then AText := TGLEdit(C.Ctl).Text
  else if C.Ctl is TGLMemo then AText := TGLMemo(C.Ctl).Text
  else if C.Ctl is TGLTabStrip then Result := TGLTabStrip(C.Ctl).TabIndex
  else if C.Ctl is TGLPageControl then Result := TGLPageControl(C.Ctl).ActivePageIndex
  else if C.Ctl is TGLScrollBar then Result := TGLScrollBar(C.Ctl).Position
  else if C.Ctl is TGLList then Result := TGLList(C.Ctl).ItemIndex
  else if C.Ctl is TGLListView then Result := TGLListView(C.Ctl).ItemIndex
  else if C.Ctl is TGLTree then
  begin
    nd := TGLTree(C.Ctl).Selected;
    if nd <> nil then AText := nd.Text;
  end;
end;

procedure TPyUiBinder.UserChanged(C: TPyCtl; const AEvent: string);
var
  p: TPyParam;
  v: Double;
  txt, ev: string;
begin
  v := ValueOf(C, txt);
  if ParamOf(C, p) then
  begin
    if C.NormMapped then v := p.FromNorm(v);
    FHost.SetParam(p.Id, v);
    if Assigned(FOnParam) then FOnParam(p.Id, v);
    Exit;
  end;
  ev := AEvent;
  if (C.Ctl is TGLCombo) or (C.Ctl is TGLList) or (C.Ctl is TGLListView) or (C.Ctl is TGLTree) or
     (C.Ctl is TGLTabStrip) or (C.Ctl is TGLPageControl) then
    ev := 'select';
  if txt <> '' then FHost.SendEvent(C.Id, ev, txt)
  else FHost.SendEvent(C.Id, ev, FloatToStr(v, TFormatSettings.Invariant));
end;

procedure TPyUiBinder.SendMouse(const AId, AKind: string; X, Y, AButton: Integer);
begin
  FHost.SendEvent(AId, AKind, '', X, Y, AButton);
end;

{ ---- messages from the plug-in ---- }

procedure TPyUiBinder.ApplyUi(const AJson: string);
var
  v: TJSONValue;
  o, prm, ctls, props: TJSONObject;
  rep: TJSONArray;
  pair: TJSONPair;
  c: TPyCtl;
  p: TPyParam;
  i: Integer;
begin
  v := TJSONObject.ParseJSONValue(AJson);
  try
    if not (v is TJSONObject) then Exit;
    o := TJSONObject(v);
    prm := o.GetValue('params') as TJSONObject;
    if prm <> nil then
      for c in FCtls do
        if c.Param <> '' then
          for pair in prm do
            if SameText(pair.JsonString.Value, c.Param) and ParamOf(c, p) then
            begin
              p := FHost.GetParam(c.ParamIdx);
              PushParam(c, p);
            end;
    ctls := o.GetValue('controls') as TJSONObject;
    if ctls <> nil then
      for pair in ctls do
        if FById.TryGetValue(pair.JsonString.Value, c) and (pair.JsonValue is TJSONObject) then
        begin
          props := TJSONObject(pair.JsonValue);
          ApplyProps(c, props);
        end;
    rep := o.GetValue('repaint') as TJSONArray;
    if rep <> nil then
      for i := 0 to rep.Count - 1 do
        for c in FCtls do
          if (c.Ctl is TPyCanvasView) and ((rep.Items[i].Value = '*') or (rep.Items[i].Value = c.Id)) then
            c.Dirty := True;
  finally
    v.Free;
  end;
end;

procedure TPyUiBinder.ApplyPaint(const AJson: string);
var
  v: TJSONValue;
  o: TJSONObject;
  c: TPyCtl;
  cmds: TJSONArray;
begin
  v := TJSONObject.ParseJSONValue(AJson);
  try
    if not (v is TJSONObject) then Exit;
    o := TJSONObject(v);
    if not FById.TryGetValue(o.GetValue<string>('id', ''), c) then Exit;
    c.Pending := False;
    cmds := o.GetValue('cmds') as TJSONArray;
    if (cmds <> nil) and (c.Ctl is TPyCanvasView) then
      TPyCanvasView(c.Ctl).SetCommands(TJSONArray(cmds.Clone));
  finally
    v.Free;
  end;
end;

procedure TPyUiBinder.Pump(ATick: Boolean);
var
  m: TPyMsg;
  c: TPyCtl;
  now_: UInt64;
  sep: Integer;
begin
  now_ := GetTickCount64;
  FMsgs.Clear;
  FHost.TakeMessages(FMsgs);
  for m in FMsgs do
    case m.Kind of
      pmLog:
        if Assigned(FOnLog) then
        begin
          sep := Pos('|', m.Text);
          if sep > 0 then FOnLog(Copy(m.Text, 1, sep - 1), Copy(m.Text, sep + 1, MaxInt))
          else FOnLog('info', m.Text);
        end;
      pmError:
        if Assigned(FOnError) then FOnError(m.Text);
      pmUi: ApplyUi(m.Text);
      pmPaint: ApplyPaint(m.Text);
    end;
  if FHost.Dead or not FHost.Ready then Exit;
  for c in FCtls do
    if c.Ctl is TPyCanvasView then
    begin
      if c.Pending and (now_ - c.PendingSince > 1500) then c.Pending := False;
      if c.Pending or not TWinControl(c.Ctl).Showing then Continue;
      if c.Dirty or ((c.Fps > 0) and (now_ - c.LastReq >= UInt64(1000 div c.Fps))) then
      begin
        c.Dirty := False;
        c.Pending := True;
        c.PendingSince := now_;
        c.LastReq := now_;
        FHost.RequestPaint(c.Id, c.Ctl.Width, c.Ctl.Height);
      end;
    end;
  if ATick and (now_ - FLastTick >= 50) then
  begin
    FLastTick := now_;
    FHost.Tick;
  end;
end;

end.
