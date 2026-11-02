unit UDAW.GL.Canvas;

{ OpenGL 3.3 core 2D canvas for UDAW's custom-drawn surfaces (the Timeline).

  TGLCanvas mirrors the subset of TCanvas the Timeline painter uses (Pen,
  Brush, Font, FillRect, Rectangle, RoundRect, MoveTo/LineTo, Polygon,
  TextOut/TextRect/TextWidth/TextHeight, Draw) so the painter keeps its shape,
  but every call is recorded into one vertex stream and drawn in a handful of
  batched glDrawArrays calls per frame. Text is rasterised once by GDI into a
  cached single-channel texture and tinted by the shader.

  TGLView is the design-time control that owns the window, the 3.3 core
  context and a TGLCanvas. It is an ordinary TWinControl, so it is placed on
  the form like any other control and takes the same mouse/drag events.

  The GL entry points come from ThirdParty\dglOpenGL (loaded at run time from
  opengl32.dll; nothing is linked). If a 3.3 context cannot be created the
  control paints an explanatory message instead of drawing garbage. }

interface

uses
  Winapi.Windows, Winapi.Messages, Winapi.ShellAPI, System.SysUtils, System.Classes,
  System.Types, System.UITypes, System.Math, System.StrUtils, System.Generics.Collections,
  Vcl.Controls, Vcl.Graphics, Vcl.Menus;

type
  { set by UDAW.GL.Menus: shows a TPopupMenu in GL (X, Y in screen coordinates) }
  TGLContextMenuProc = procedure(ACtrl: TControl; AMenu: TPopupMenu; X, Y: Integer);

var
  GLContextMenuHandler: TGLContextMenuProc;

type
  { implemented by a form that paints its own (e.g. gradient) background behind GL widgets: it
    tells a widget "transparent" over it which colour lies behind ARect (the widget's bounds in
    the implementing control's client coordinates) }
  IGLBackdrop = interface
    ['{6E0B7D3A-5C1F-4B8E-9A52-3F7C1D2E8A41}']
    function GLBackdropColor(const ARect: TRect): TColor;
  end;

{ the colour behind AControl as given by the nearest parent that implements IGLBackdrop;
  False when no parent does }
function GLParentBackdrop(AControl: TControl; out AColor: TColor): Boolean;

{ the graphics driver's own account of itself, one "Key|Value" per entry (vendor, renderer, versions,
  limits, video memory, every extension); a single "status|..." entry when no 3.3 context exists }
function GLDriverReport: TArray<string>;

{ Frame statistics: every GL surface notes each frame it draws. GLSampleFrames reports, for the time
  since its previous call, the busiest surface's frames per second (the screen's render rate), all
  surfaces' frames per second together, and how many surfaces drew at all. }
procedure GLSampleFrames(out AFps, ADrawsPerSec: Double; out ASurfaces: Integer);

type
  TGLPen = class
  public
    Color: TColor;
    Width: Integer;
    Style: TPenStyle;
    constructor Create;
  end;

  TGLBrush = class
  public
    Color: TColor;
    Style: TBrushStyle;
    constructor Create;
  end;

  TGLFont = class
  private
    function GetSize: Integer;
    procedure SetSize(AValue: Integer);
  public
    Color: TColor;
    Height: Integer;
    Name: string;
    Style: TFontStyles;
    constructor Create;
    { point size at 96 dpi, like TFont.Size }
    property Size: Integer read GetSize write SetSize;
  end;

  TGLDrawCmd = record
    Mode: Integer;       // 0 solid, 1 text (R8 alpha mask), 2 RGBA picture
    Tex: Cardinal;
    HasClip: Boolean;
    Clip: TRect;
    First, Count: Integer;
  end;

  PGLDrawCmd = ^TGLDrawCmd;

  TGLTextEntry = record
    Tex: Cardinal;
    W, H: Integer;
    LastFrame: Int64;
  end;

  { receives the drawing instead of the screen: a canvas with a recorder attached turns its
    lines, filled boxes, ellipses and text into calls here (no GL context needed) - used to write
    the Score to a PDF }
  TGLRecorder = class abstract
  public
    procedure Line(X1, Y1, X2, Y2: Integer; AColor: TColor; AWidth: Integer); virtual; abstract;
    procedure Fill(const R: TRect; AColor: TColor); virtual; abstract;
    procedure Oval(const R: TRect; AFill: Boolean; AFillColor: TColor; AStroke: Boolean;
      AStrokeColor: TColor; AStrokeW: Integer); virtual; abstract;
    procedure Text(X, Y: Integer; const S, AFontName: string; AFontPx: Integer;
      AStyle: TFontStyles; AColor: TColor; ACellH: Integer); virtual; abstract;
  end;

  TGLCanvas = class
  private
    FRec: TGLRecorder;
    FPen: TGLPen;
    FBrush: TGLBrush;
    FFont: TGLFont;
    FW, FH: Integer;
    FPenX, FPenY: Integer;
    FFrame: Int64;
    FAlpha: Single;
    FVerts: TArray<Single>;
    FVertCount: Integer;
    FCmds: TArray<TGLDrawCmd>;
    FCmdCount: Integer;
    FClipStack: TList<TRect>;
    FClip: TRect;
    FHasClip: Boolean;
    FClipEmpty: Boolean;
    FProg: Cardinal;
    FVao, FVbo: Cardinal;
    FUViewport, FUMode, FUTex: Integer;
    FReady: Boolean;
    FTextCache: TDictionary<string, TGLTextEntry>;
    FWidthCache: TDictionary<string, Integer>;
    FTransient: TList<Cardinal>;
    FMeasure: TBitmap;
    procedure AddVertex(X, Y, U, V, R, G, B, A: Single);
    procedure AddQuad(X0, Y0, X1, Y1, X2, Y2, X3, Y3: Single; AColor: TColor;
      AMode: Integer; ATex: Cardinal; U0, V0, U1, V1: Single);
    procedure Solid(X0, Y0, X1, Y1: Single; AColor: TColor);
    procedure BeginPrim(AMode: Integer; ATex: Cardinal);
    procedure SegmentF(X1, Y1, X2, Y2: Single; AWidth: Single; AColor: TColor);
    procedure FeatherPoly(const APts: array of TPointF; AColor: TColor);
    procedure DashedSegmentF(X1, Y1, X2, Y2: Single; AWidth: Single; AColor: TColor);
    procedure OutlinePoly(const APts: array of TPointF; AClosed: Boolean);
    procedure FillPoly(const APts: array of TPointF; AColor: TColor);
    procedure ApplyMeasureFont;
    function FontKey: string;
    function TextTexture(const AText: string): TGLTextEntry;
    function CompileProgram: Boolean;
    procedure Flush;
    procedure RecomputeClip;
  public
    constructor Create;
    destructor Destroy; override;
    { must be called with the GL context current }
    function Initialize: Boolean;
    procedure Release;
    procedure BeginFrame(AWidth, AHeight: Integer);
    procedure EndFrame;
    { pen, brush and font back to their defaults (a canvas shared between views) }
    procedure ResetState;

    procedure PushClip(const R: TRect);
    procedure PopClip;

    procedure FillRect(const R: TRect);
    { a rectangle blended from ATop to ABottom (or left to right when AHorizontal) in one quad }
    procedure GradientRect(const R: TRect; ATop, ABottom: TColor; AHorizontal: Boolean = False);
    procedure Rectangle(L, T, R, B: Integer); overload;
    procedure Rectangle(const R: TRect); overload;
    procedure RoundRect(L, T, R, B, RW, RH: Integer);
    procedure Ellipse(L, T, R, B: Integer);
    procedure MoveTo(X, Y: Integer);
    procedure LineTo(X, Y: Integer);
    procedure Polygon(const APts: array of TPoint);
    procedure TextOut(X, Y: Integer; const S: string);
    { text turned a quarter turn anticlockwise (reads bottom to top); X, Y is the top-left
      of the turned text's box, which is TextHeight wide and TextWidth tall }
    procedure TextOutVertical(X, Y: Integer; const S: string);
    procedure TextRect(const R: TRect; X, Y: Integer; const S: string);
    function TextWidth(const S: string): Integer;
    function TextHeight(const S: string): Integer;
    procedure Draw(X, Y: Integer; ABitmap: TBitmap);
    procedure StretchDraw(const R: TRect; ABitmap: TBitmap);
    procedure SetPixel(X, Y: Integer; AColor: TColor);

    property Pen: TGLPen read FPen;
    property Brush: TGLBrush read FBrush;
    property Font: TGLFont read FFont;
    property Ready: Boolean read FReady;
    { when set, drawing goes to the recorder and not to GL }
    property Recorder: TGLRecorder read FRec write FRec;
    { 0..1 opacity applied to everything drawn until changed (reset every frame) }
    property Alpha: Single read FAlpha write FAlpha;
    property Width: Integer read FW;
    property Height: Integer read FH;
  end;

  TGLDropFilesEvent = procedure(Sender: TObject; ADrop: HDROP; const APoint: TPoint) of object;

  TGLView = class(TCustomControl)
  private
    FOnDropFiles: TGLDropFilesEvent;
    FFbo, FRbo: Cardinal;
    FTargetW, FTargetH: Integer;
    FFrameBmp: TBitmap;
    FDC: HDC;
    FRC: HGLRC;
    FGL: TGLCanvas;
    FOnPaint: TNotifyEvent;
    FFailure: string;
    FShared: Boolean;
    FWantArrows: Boolean;
    function GetGL: TGLCanvas;
    procedure PaintShared;
    procedure WMGetDlgCode(var Msg: TWMGetDlgCode); message WM_GETDLGCODE;
    procedure WMEraseBkgnd(var Msg: TWMEraseBkgnd); message WM_ERASEBKGND;
    procedure WMDropFiles(var Msg: TWMDropFiles); message WM_DROPFILES;
    procedure WMContextMenu(var Msg: TWMContextMenu); message WM_CONTEXTMENU;
    procedure ReleaseContext;
    function EnsureTarget(AW, AH: Integer): Boolean;
    procedure ReleaseTarget;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure CreateWnd; override;
    procedure DestroyWnd; override;
    procedure Paint; override;
    { draws one frame on GL; the default raises OnPaint, subclasses override }
    procedure PaintGL; virtual;
    { sets up the shared canvas (font, ...) just before PaintGL; a shared canvas is
      reset to defaults for every view, so per-control settings belong here }
    procedure PrepareCanvas(ACanvas: TGLCanvas); virtual;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { the batched 2D canvas; only valid inside OnPaint }
    property GL: TGLCanvas read GetGL;
    { true: draw through the one GL context shared by every such view (no context,
      framebuffer or shader set of its own) - for small, numerous controls. Set it
      in the constructor, before the window exists. }
    property SharedSurface: Boolean read FShared write FShared;
    function GLReady: Boolean;
    property Failure: string read FFailure;
  published
    property Align;
    property Anchors;
    property Cursor;
    property Enabled;
    property PopupMenu;
    property ShowHint;
    property Visible;
    { True: the cursor keys go to this view's key handlers instead of moving the focus }
    property WantArrows: Boolean read FWantArrows write FWantArrows default False;
    property OnClick;
    property OnDropFiles: TGLDropFilesEvent read FOnDropFiles write FOnDropFiles;
    property OnDblClick;
    property OnDragDrop;
    property OnDragOver;
    property OnMouseDown;
    property OnMouseMove;
    property OnMouseUp;
    property OnMouseLeave;
    property OnMouseWheel;
    property OnPaint: TNotifyEvent read FOnPaint write FOnPaint;
  end;

implementation

uses UDAW.DSP.MathTables,
  dglOpenGL;

var
  GFrameCounts: TDictionary<TObject, Integer>;
  GFrameStamp: UInt64;

procedure GLNoteFrame(AView: TObject);
var
  n: Integer;
begin
  if GFrameCounts = nil then
  begin
    GFrameCounts := TDictionary<TObject, Integer>.Create;
    GFrameStamp := GetTickCount64;
  end;
  if GFrameCounts.TryGetValue(AView, n) then GFrameCounts[AView] := n + 1
  else GFrameCounts.Add(AView, 1);
end;

procedure GLSampleFrames(out AFps, ADrawsPerSec: Double; out ASurfaces: Integer);
var
  secs: Double;
  n, busiest, total: Integer;
  now_: UInt64;
begin
  AFps := 0;
  ADrawsPerSec := 0;
  ASurfaces := 0;
  if GFrameCounts = nil then Exit;
  now_ := GetTickCount64;
  secs := (now_ - GFrameStamp) / 1000.0;
  busiest := 0;
  total := 0;
  for n in GFrameCounts.Values do
  begin
    if n > busiest then busiest := n;
    Inc(total, n);
  end;
  ASurfaces := GFrameCounts.Count;
  if secs > 0.001 then
  begin
    AFps := busiest / secs;
    ADrawsPerSec := total / secs;
  end;
  GFrameCounts.Clear;
  GFrameStamp := now_;
end;


function GLParentBackdrop(AControl: TControl; out AColor: TColor): Boolean;
var
  p: TWinControl;
  b: IGLBackdrop;
  tl: TPoint;
begin
  Result := False;
  AColor := clNone;
  if AControl = nil then Exit;
  p := AControl.Parent;
  while p <> nil do
  begin
    if Supports(p, IGLBackdrop, b) then
    begin
      tl := p.ScreenToClient(AControl.ClientToScreen(Point(0, 0)));
      AColor := b.GLBackdropColor(Rect(tl.X, tl.Y, tl.X + AControl.Width, tl.Y + AControl.Height));
      Exit(True);
    end;
    p := p.Parent;
  end;
end;


const
  VERT_FLOATS = 8;
  TEXT_CACHE_LIMIT = 800;
  DASH_ON = 6;
  DASH_OFF = 3;

  VERT_SRC: AnsiString =
    '#version 330 core'#10 +
    'layout(location=0) in vec2 aPos;'#10 +
    'layout(location=1) in vec2 aUV;'#10 +
    'layout(location=2) in vec4 aCol;'#10 +
    'uniform vec2 uViewport;'#10 +
    'out vec2 vUV;'#10 +
    'out vec4 vCol;'#10 +
    'void main(){'#10 +
    '  vUV = aUV; vCol = aCol;'#10 +
    '  gl_Position = vec4(aPos.x / uViewport.x * 2.0 - 1.0,'#10 +
    '                     1.0 - aPos.y / uViewport.y * 2.0, 0.0, 1.0);'#10 +
    '}'#10;

  FRAG_SRC: AnsiString =
    '#version 330 core'#10 +
    'in vec2 vUV;'#10 +
    'in vec4 vCol;'#10 +
    'uniform sampler2D uTex;'#10 +
    'uniform int uMode;'#10 +
    'out vec4 outColor;'#10 +
    'void main(){'#10 +
    '  if (uMode == 1) outColor = vec4(vCol.rgb, vCol.a * texture(uTex, vUV).r);'#10 +
    '  else if (uMode == 2) outColor = vec4(texture(uTex, vUV).rgb, vCol.a);'#10 +
    '  else outColor = vCol;'#10 +
    '}'#10;

{ ---- pen / brush / font ---- }

constructor TGLPen.Create;
begin
  inherited Create;
  Color := clBlack;
  Width := 1;
  Style := psSolid;
end;

constructor TGLBrush.Create;
begin
  inherited Create;
  Color := clWhite;
  Style := bsSolid;
end;

function TGLFont.GetSize: Integer;
begin
  Result := Round(-Height * 72 / 96);
end;

procedure TGLFont.SetSize(AValue: Integer);
begin
  Height := -Round(AValue * 96 / 72);
end;

constructor TGLFont.Create;
begin
  inherited Create;
  Color := clBlack;
  Height := -11;
  Name := 'Segoe UI';
  Style := [];
end;

{ ---- TGLCanvas ---- }

constructor TGLCanvas.Create;
begin
  inherited Create;
  FPen := TGLPen.Create;
  FBrush := TGLBrush.Create;
  FFont := TGLFont.Create;
  FClipStack := TList<TRect>.Create;
  FTextCache := TDictionary<string, TGLTextEntry>.Create;
  FWidthCache := TDictionary<string, Integer>.Create;
  FTransient := TList<Cardinal>.Create;
  FAlpha := 1;
  FMeasure := TBitmap.Create;
  FMeasure.PixelFormat := pf24bit;
  FMeasure.SetSize(8, 8);
  SetLength(FVerts, 65536 * VERT_FLOATS);
  SetLength(FCmds, 256);
end;

destructor TGLCanvas.Destroy;
begin
  FMeasure.Free;
  FTransient.Free;
  FWidthCache.Free;
  FTextCache.Free;
  FClipStack.Free;
  FFont.Free;
  FBrush.Free;
  FPen.Free;
  inherited Destroy;
end;

function TGLCanvas.CompileProgram: Boolean;

  function Compile(AKind: Cardinal; const ASrc: AnsiString): Cardinal;
  var
    sh: Cardinal;
    p: PAnsiChar;
    ok: GLint;
  begin
    sh := glCreateShader(AKind);
    p := PAnsiChar(ASrc);
    glShaderSource(sh, 1, @p, nil);
    glCompileShader(sh);
    glGetShaderiv(sh, GL_COMPILE_STATUS, @ok);
    if ok = 0 then
    begin
      glDeleteShader(sh);
      Result := 0;
    end
    else
      Result := sh;
  end;

var
  vs, fs: Cardinal;
  ok: GLint;
begin
  Result := False;
  vs := Compile(GL_VERTEX_SHADER, VERT_SRC);
  fs := Compile(GL_FRAGMENT_SHADER, FRAG_SRC);
  if (vs = 0) or (fs = 0) then
  begin
    if vs <> 0 then glDeleteShader(vs);
    if fs <> 0 then glDeleteShader(fs);
    Exit;
  end;
  FProg := glCreateProgram;
  glAttachShader(FProg, vs);
  glAttachShader(FProg, fs);
  glLinkProgram(FProg);
  glDeleteShader(vs);
  glDeleteShader(fs);
  glGetProgramiv(FProg, GL_LINK_STATUS, @ok);
  if ok = 0 then
  begin
    glDeleteProgram(FProg);
    FProg := 0;
    Exit;
  end;
  FUViewport := glGetUniformLocation(FProg, 'uViewport');
  FUMode := glGetUniformLocation(FProg, 'uMode');
  FUTex := glGetUniformLocation(FProg, 'uTex');
  Result := True;
end;

function TGLCanvas.Initialize: Boolean;
begin
  Result := False;
  if not GL_VERSION_3_3 then Exit;
  if not CompileProgram then Exit;
  glGenVertexArrays(1, @FVao);
  glGenBuffers(1, @FVbo);
  glBindVertexArray(FVao);
  glBindBuffer(GL_ARRAY_BUFFER, FVbo);
  glEnableVertexAttribArray(0);
  glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, VERT_FLOATS * 4, Pointer(0));
  glEnableVertexAttribArray(1);
  glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, VERT_FLOATS * 4, Pointer(8));
  glEnableVertexAttribArray(2);
  glVertexAttribPointer(2, 4, GL_FLOAT, GL_FALSE, VERT_FLOATS * 4, Pointer(16));
  glBindVertexArray(0);
  FReady := True;
  Result := True;
end;

procedure TGLCanvas.Release;
var
  e: TGLTextEntry;
  t: Cardinal;
begin
  if not FReady then Exit;
  for e in FTextCache.Values do
    glDeleteTextures(1, @e.Tex);
  FTextCache.Clear;
  for t in FTransient do
    glDeleteTextures(1, @t);
  FTransient.Clear;
  glDeleteBuffers(1, @FVbo);
  glDeleteVertexArrays(1, @FVao);
  glDeleteProgram(FProg);
  FReady := False;
end;

procedure TGLCanvas.BeginFrame(AWidth, AHeight: Integer);
var
  t: Cardinal;
  stale: TList<string>;
  k: string;
  e: TGLTextEntry;
begin
  Inc(FFrame);
  FAlpha := 1;
  FW := AWidth;
  FH := AHeight;
  FVertCount := 0;
  FCmdCount := 0;
  FClipStack.Clear;
  FHasClip := False;
  FClipEmpty := False;
  FPenX := 0;
  FPenY := 0;
  for t in FTransient do
    glDeleteTextures(1, @t);
  FTransient.Clear;
  { text strings that stopped being drawn are dropped once the cache is large }
  if FTextCache.Count > TEXT_CACHE_LIMIT then
  begin
    stale := TList<string>.Create;
    try
      for k in FTextCache.Keys do
        if FTextCache[k].LastFrame < FFrame - 2 then stale.Add(k);
      for k in stale do
      begin
        e := FTextCache[k];
        glDeleteTextures(1, @e.Tex);
        FTextCache.Remove(k);
      end;
    finally
      stale.Free;
    end;
  end;
  if FWidthCache.Count > 8192 then FWidthCache.Clear;
  glViewport(0, 0, AWidth, AHeight);
  glDisable(GL_SCISSOR_TEST);
  glDisable(GL_DEPTH_TEST);
  glClearColor(0, 0, 0, 1);
  glClear(GL_COLOR_BUFFER_BIT);
end;

procedure TGLCanvas.ResetState;
begin
  FPen.Color := clBlack;
  FPen.Width := 1;
  FPen.Style := psSolid;
  FBrush.Color := clWhite;
  FBrush.Style := bsSolid;
  FFont.Color := clBlack;
  FFont.Height := -11;
  FFont.Name := 'Segoe UI';
  FFont.Style := [];
end;

procedure TGLCanvas.EndFrame;
begin
  Flush;
end;

procedure TGLCanvas.Flush;
var
  i: Integer;
  c: TGLDrawCmd;
begin
  if (FVertCount = 0) or not FReady then Exit;
  glEnable(GL_BLEND);
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  glUseProgram(FProg);
  glUniform2f(FUViewport, FW, FH);
  glUniform1i(FUTex, 0);
  glBindVertexArray(FVao);
  glBindBuffer(GL_ARRAY_BUFFER, FVbo);
  glBufferData(GL_ARRAY_BUFFER, FVertCount * VERT_FLOATS * 4, @FVerts[0], GL_STREAM_DRAW);
  for i := 0 to FCmdCount - 1 do
  begin
    c := FCmds[i];
    if c.HasClip then
    begin
      glEnable(GL_SCISSOR_TEST);
      glScissor(c.Clip.Left, FH - c.Clip.Bottom, c.Clip.Width, c.Clip.Height);
    end
    else
      glDisable(GL_SCISSOR_TEST);
    glUniform1i(FUMode, c.Mode);
    if c.Mode <> 0 then
    begin
      glActiveTexture(GL_TEXTURE0);
      glBindTexture(GL_TEXTURE_2D, c.Tex);
    end;
    glDrawArrays(GL_TRIANGLES, c.First, c.Count);
  end;
  glDisable(GL_SCISSOR_TEST);
  glBindVertexArray(0);
  glUseProgram(0);
  FVertCount := 0;
  FCmdCount := 0;
end;

{ ---- clip ---- }

procedure TGLCanvas.RecomputeClip;
var
  i: Integer;
  r: TRect;
begin
  FHasClip := FClipStack.Count > 0;
  FClipEmpty := False;
  if not FHasClip then Exit;
  r := FClipStack[0];
  for i := 1 to FClipStack.Count - 1 do
    IntersectRect(r, r, FClipStack[i]);
  r.Left := Max(0, r.Left);
  r.Top := Max(0, r.Top);
  r.Right := Min(FW, r.Right);
  r.Bottom := Min(FH, r.Bottom);
  FClip := r;
  FClipEmpty := (r.Right <= r.Left) or (r.Bottom <= r.Top);
end;

procedure TGLCanvas.PushClip(const R: TRect);
begin
  FClipStack.Add(R);
  RecomputeClip;
end;

procedure TGLCanvas.PopClip;
begin
  if FClipStack.Count > 0 then FClipStack.Delete(FClipStack.Count - 1);
  RecomputeClip;
end;

{ ---- vertex stream ---- }

procedure TGLCanvas.AddVertex(X, Y, U, V, R, G, B, A: Single);
var
  o: Integer;
begin
  o := FVertCount * VERT_FLOATS;
  if o + VERT_FLOATS > Length(FVerts) then
    SetLength(FVerts, Length(FVerts) * 2);
  FVerts[o] := X;
  FVerts[o + 1] := Y;
  FVerts[o + 2] := U;
  FVerts[o + 3] := V;
  FVerts[o + 4] := R;
  FVerts[o + 5] := G;
  FVerts[o + 6] := B;
  FVerts[o + 7] := A;
  Inc(FVertCount);
end;

procedure TGLCanvas.BeginPrim(AMode: Integer; ATex: Cardinal);
var
  c: PGLDrawCmd;
begin
  if FCmdCount > 0 then
  begin
    c := @FCmds[FCmdCount - 1];
    if (c.Mode = AMode) and (c.Tex = ATex) and (c.HasClip = FHasClip) and
       ((not FHasClip) or (c.Clip = FClip)) and (c.First + c.Count = FVertCount) then
      Exit;
  end;
  if FCmdCount = Length(FCmds) then SetLength(FCmds, FCmdCount * 2);
  c := @FCmds[FCmdCount];
  c.Mode := AMode;
  c.Tex := ATex;
  c.HasClip := FHasClip;
  c.Clip := FClip;
  c.First := FVertCount;
  c.Count := 0;
  Inc(FCmdCount);
end;

procedure TGLCanvas.AddQuad(X0, Y0, X1, Y1, X2, Y2, X3, Y3: Single; AColor: TColor;
  AMode: Integer; ATex: Cardinal; U0, V0, U1, V1: Single);
var
  rgb: Integer;
  r, g, b: Single;
begin
  if FClipEmpty then Exit;
  rgb := ColorToRGB(AColor);
  r := (rgb and $FF) / 255;
  g := ((rgb shr 8) and $FF) / 255;
  b := ((rgb shr 16) and $FF) / 255;
  BeginPrim(AMode, ATex);
  AddVertex(X0, Y0, U0, V0, r, g, b, FAlpha);
  AddVertex(X1, Y1, U1, V0, r, g, b, FAlpha);
  AddVertex(X2, Y2, U1, V1, r, g, b, FAlpha);
  AddVertex(X0, Y0, U0, V0, r, g, b, FAlpha);
  AddVertex(X2, Y2, U1, V1, r, g, b, FAlpha);
  AddVertex(X3, Y3, U0, V1, r, g, b, FAlpha);
  Inc(FCmds[FCmdCount - 1].Count, 6);
end;

procedure TGLCanvas.Solid(X0, Y0, X1, Y1: Single; AColor: TColor);
begin
  AddQuad(X0, Y0, X1, Y0, X1, Y1, X0, Y1, AColor, 0, 0, 0, 0, 0, 0);
end;

{ ---- lines ---- }

procedure TGLCanvas.SegmentF(X1, Y1, X2, Y2: Single; AWidth: Single; AColor: TColor);
var
  dx, dy, len, nx, ny, h: Single;
begin
  dx := X2 - X1;
  dy := Y2 - Y1;
  len := Sqrt(dx * dx + dy * dy);
  if len < 0.0001 then Exit;
  h := AWidth / 2;
  nx := -dy / len * h;
  ny := dx / len * h;
  AddQuad(X1 + nx, Y1 + ny, X2 + nx, Y2 + ny, X2 - nx, Y2 - ny, X1 - nx, Y1 - ny,
    AColor, 0, 0, 0, 0, 0, 0);
end;

{ Anti-aliases the edge of a filled curved shape: a 1 px line of the fill colour at half strength along
  the outline, so the edge pixels take half coverage (half inside, half outside the shape) instead of
  stepping from fill to nothing. The jagged stair-steps on curves are what this removes. }
procedure TGLCanvas.FeatherPoly(const APts: array of TPointF; AColor: TColor);
var
  i, n: Integer;
  keep: Single;
begin
  n := Length(APts);
  if n < 3 then Exit;
  keep := FAlpha;
  FAlpha := keep * 0.5;
  for i := 0 to n - 2 do
    SegmentF(APts[i].X, APts[i].Y, APts[i + 1].X, APts[i + 1].Y, 1, AColor);
  SegmentF(APts[n - 1].X, APts[n - 1].Y, APts[0].X, APts[0].Y, 1, AColor);
  FAlpha := keep;
end;

procedure TGLCanvas.DashedSegmentF(X1, Y1, X2, Y2: Single; AWidth: Single; AColor: TColor);
var
  dx, dy, len, pos, e: Single;
begin
  dx := X2 - X1;
  dy := Y2 - Y1;
  len := Sqrt(dx * dx + dy * dy);
  if len < 0.0001 then Exit;
  dx := dx / len;
  dy := dy / len;
  pos := 0;
  while pos < len do
  begin
    e := Min(pos + DASH_ON, len);
    SegmentF(X1 + dx * pos, Y1 + dy * pos, X1 + dx * e, Y1 + dy * e, AWidth, AColor);
    pos := pos + DASH_ON + DASH_OFF;
  end;
end;

procedure TGLCanvas.MoveTo(X, Y: Integer);
begin
  FPenX := X;
  FPenY := Y;
end;

procedure TGLCanvas.LineTo(X, Y: Integer);
var
  w, off: Integer;
  lo, hi: Integer;
begin
  if FRec <> nil then
  begin
    if FPen.Style <> psClear then FRec.Line(FPenX, FPenY, X, Y, FPen.Color, Max(1, FPen.Width));
    FPenX := X;
    FPenY := Y;
    Exit;
  end;
  if FPen.Style <> psClear then
  begin
    w := Max(1, FPen.Width);
    off := (w - 1) div 2;
    { GDI semantics: the end pixel is not drawn; axis-aligned lines are snapped
      to whole pixels so waveform columns and grid lines stay razor sharp }
    if (X = FPenX) and (Y <> FPenY) then
    begin
      if Y > FPenY then begin lo := FPenY; hi := Y; end
      else begin lo := Y + 1; hi := FPenY + 1; end;
      if FPen.Style = psSolid then
        Solid(X - off, lo, X - off + w, hi, FPen.Color)
      else
        DashedSegmentF(X + 0.5, lo, X + 0.5, hi, w, FPen.Color);
    end
    else if (Y = FPenY) and (X <> FPenX) then
    begin
      if X > FPenX then begin lo := FPenX; hi := X; end
      else begin lo := X + 1; hi := FPenX + 1; end;
      if FPen.Style = psSolid then
        Solid(lo, Y - off, hi, Y - off + w, FPen.Color)
      else
        DashedSegmentF(lo, Y + 0.5, hi, Y + 0.5, w, FPen.Color);
    end
    else if (X <> FPenX) or (Y <> FPenY) then
    begin
      if FPen.Style = psSolid then
        SegmentF(FPenX + 0.5, FPenY + 0.5, X + 0.5, Y + 0.5, w, FPen.Color)
      else
        DashedSegmentF(FPenX + 0.5, FPenY + 0.5, X + 0.5, Y + 0.5, w, FPen.Color);
    end;
  end;
  FPenX := X;
  FPenY := Y;
end;

{ ---- shapes ---- }

procedure TGLCanvas.FillPoly(const APts: array of TPointF; AColor: TColor);
var
  i: Integer;
  rgb: Integer;
  r, g, b: Single;
begin
  if (Length(APts) < 3) or FClipEmpty then Exit;
  rgb := ColorToRGB(AColor);
  r := (rgb and $FF) / 255;
  g := ((rgb shr 8) and $FF) / 255;
  b := ((rgb shr 16) and $FF) / 255;
  BeginPrim(0, 0);
  for i := 1 to High(APts) - 1 do
  begin
    AddVertex(APts[0].X, APts[0].Y, 0, 0, r, g, b, FAlpha);
    AddVertex(APts[i].X, APts[i].Y, 0, 0, r, g, b, FAlpha);
    AddVertex(APts[i + 1].X, APts[i + 1].Y, 0, 0, r, g, b, FAlpha);
    Inc(FCmds[FCmdCount - 1].Count, 3);
  end;
end;

procedure TGLCanvas.OutlinePoly(const APts: array of TPointF; AClosed: Boolean);
var
  i, n: Integer;
  w: Single;
begin
  if FPen.Style = psClear then Exit;
  w := Max(1, FPen.Width);
  n := Length(APts);
  for i := 0 to n - 2 do
    if FPen.Style = psSolid then
      SegmentF(APts[i].X, APts[i].Y, APts[i + 1].X, APts[i + 1].Y, w, FPen.Color)
    else
      DashedSegmentF(APts[i].X, APts[i].Y, APts[i + 1].X, APts[i + 1].Y, w, FPen.Color);
  if AClosed and (n > 2) then
    if FPen.Style = psSolid then
      SegmentF(APts[n - 1].X, APts[n - 1].Y, APts[0].X, APts[0].Y, w, FPen.Color)
    else
      DashedSegmentF(APts[n - 1].X, APts[n - 1].Y, APts[0].X, APts[0].Y, w, FPen.Color);
end;

procedure TGLCanvas.GradientRect(const R: TRect; ATop, ABottom: TColor; AHorizontal: Boolean);
var
  c1, c2: Integer;
  r1, g1, b1, r2, g2, b2: Single;
  x0, y0, x1, y1: Single;
begin
  if FClipEmpty or (R.Right <= R.Left) or (R.Bottom <= R.Top) then Exit;
  c1 := ColorToRGB(ATop);
  c2 := ColorToRGB(ABottom);
  r1 := (c1 and $FF) / 255; g1 := ((c1 shr 8) and $FF) / 255; b1 := ((c1 shr 16) and $FF) / 255;
  r2 := (c2 and $FF) / 255; g2 := ((c2 shr 8) and $FF) / 255; b2 := ((c2 shr 16) and $FF) / 255;
  x0 := R.Left; y0 := R.Top; x1 := R.Right; y1 := R.Bottom;
  BeginPrim(0, 0);
  if AHorizontal then
  begin
    AddVertex(x0, y0, 0, 0, r1, g1, b1, FAlpha);
    AddVertex(x1, y0, 0, 0, r2, g2, b2, FAlpha);
    AddVertex(x1, y1, 0, 0, r2, g2, b2, FAlpha);
    AddVertex(x0, y0, 0, 0, r1, g1, b1, FAlpha);
    AddVertex(x1, y1, 0, 0, r2, g2, b2, FAlpha);
    AddVertex(x0, y1, 0, 0, r1, g1, b1, FAlpha);
  end
  else
  begin
    AddVertex(x0, y0, 0, 0, r1, g1, b1, FAlpha);
    AddVertex(x1, y0, 0, 0, r1, g1, b1, FAlpha);
    AddVertex(x1, y1, 0, 0, r2, g2, b2, FAlpha);
    AddVertex(x0, y0, 0, 0, r1, g1, b1, FAlpha);
    AddVertex(x1, y1, 0, 0, r2, g2, b2, FAlpha);
    AddVertex(x0, y1, 0, 0, r2, g2, b2, FAlpha);
  end;
  Inc(FCmds[FCmdCount - 1].Count, 6);
end;

procedure TGLCanvas.FillRect(const R: TRect);
begin
  if FRec <> nil then
  begin
    if (R.Right > R.Left) and (R.Bottom > R.Top) then FRec.Fill(R, FBrush.Color);
    Exit;
  end;
  if (R.Right <= R.Left) or (R.Bottom <= R.Top) then Exit;
  Solid(R.Left, R.Top, R.Right, R.Bottom, FBrush.Color);
end;

procedure TGLCanvas.Rectangle(L, T, R, B: Integer);
var
  ins: Single;
  pts: array[0..3] of TPointF;
begin
  if (R <= L) or (B <= T) then Exit;
  if FBrush.Style = bsSolid then Solid(L, T, R, B, FBrush.Color);
  if FPen.Style = psClear then Exit;
  ins := Max(1, FPen.Width) / 2;
  pts[0] := PointF(L + ins, T + ins);
  pts[1] := PointF(R - ins, T + ins);
  pts[2] := PointF(R - ins, B - ins);
  pts[3] := PointF(L + ins, B - ins);
  OutlinePoly(pts, True);
end;

procedure TGLCanvas.Rectangle(const R: TRect);
begin
  Rectangle(R.Left, R.Top, R.Right, R.Bottom);
end;

procedure TGLCanvas.RoundRect(L, T, R, B, RW, RH: Integer);
var
  ARC_STEPS: Integer;   // segments per corner: enough that a segment is about a pixel long
  rx, ry, ins: Single;
  pts: TArray<TPointF>;
  inner: TArray<TPointF>;

  function Build(AInset: Single): TArray<TPointF>;
  var
    k, cn, n: Integer;
    ccx, ccy, ang, ax, ay: Single;
    x0, y0, x1, y1: Single;
  begin
    x0 := L + AInset; y0 := T + AInset; x1 := R - AInset; y1 := B - AInset;
    ax := Max(0, rx - AInset);
    ay := Max(0, ry - AInset);
    SetLength(Result, 4 * (ARC_STEPS + 1));
    n := 0;
    for cn := 0 to 3 do
    begin
      case cn of
        0: begin ccx := x1 - ax; ccy := y0 + ay; end;   // top-right
        1: begin ccx := x1 - ax; ccy := y1 - ay; end;   // bottom-right
        2: begin ccx := x0 + ax; ccy := y1 - ay; end;   // bottom-left
      else begin ccx := x0 + ax; ccy := y0 + ay; end;   // top-left
      end;
      for k := 0 to ARC_STEPS do
      begin
        ang := (-90 + cn * 90 + k * 90 / ARC_STEPS) * Pi / 180;
        Result[n] := PointF(ccx + FastCos(ang) * ax, ccy + FastSin(ang) * ay);
        Inc(n);
      end;
    end;
  end;

begin
  if (R <= L) or (B <= T) then Exit;
  rx := Min(RW / 2, (R - L) / 2);
  ry := Min(RH / 2, (B - T) / 2);
  ARC_STEPS := EnsureRange(Ceil(Max(rx, ry) * 1.1), 6, 24);
  if FBrush.Style = bsSolid then
  begin
    pts := Build(0);
    FillPoly(pts, FBrush.Color);
    if (rx >= 1) and (ry >= 1) then FeatherPoly(pts, FBrush.Color);
  end;
  if FPen.Style <> psClear then
  begin
    ins := Max(1, FPen.Width) / 2;
    inner := Build(ins);
    OutlinePoly(inner, True);
  end;
end;

procedure TGLCanvas.Ellipse(L, T, R, B: Integer);
var
  STEPS: Integer;
  pts: TArray<TPointF>;
  i: Integer;
  cx, cy, rx, ry, ins, a: Single;
begin
  if (R <= L) or (B <= T) then Exit;
  if FRec <> nil then
  begin
    FRec.Oval(Rect(L, T, R, B), FBrush.Style = bsSolid, FBrush.Color, FPen.Style <> psClear, FPen.Color,
      Max(1, FPen.Width));
    Exit;
  end;
  cx := (L + R) / 2;
  cy := (T + B) / 2;
  rx := (R - L) / 2;
  ry := (B - T) / 2;
  STEPS := EnsureRange(Ceil(Pi * (rx + ry) / 1.5), 24, 120);   // a segment about 1.5 px long
  SetLength(pts, STEPS);
  for i := 0 to STEPS - 1 do
  begin
    a := i * 2 * Pi / STEPS;
    pts[i] := PointF(cx + FastCos(a) * rx, cy + FastSin(a) * ry);
  end;
  if FBrush.Style = bsSolid then
  begin
    FillPoly(pts, FBrush.Color);
    FeatherPoly(pts, FBrush.Color);
  end;
  if FPen.Style <> psClear then
  begin
    ins := Max(1, FPen.Width) / 2;
    for i := 0 to STEPS - 1 do
      pts[i] := PointF(cx + FastCos(i * 2 * Pi / STEPS) * (rx - ins), cy + FastSin(i * 2 * Pi / STEPS) * (ry - ins));
    OutlinePoly(pts, True);
  end;
end;

procedure TGLCanvas.Polygon(const APts: array of TPoint);
var
  f: TArray<TPointF>;
  i: Integer;
begin
  if Length(APts) < 3 then Exit;
  SetLength(f, Length(APts));
  for i := 0 to High(APts) do
    f[i] := PointF(APts[i].X + 0.5, APts[i].Y + 0.5);
  if FBrush.Style = bsSolid then FillPoly(f, FBrush.Color);
  OutlinePoly(f, True);
end;

{ ---- text ---- }

procedure TGLCanvas.ApplyMeasureFont;
begin
  FMeasure.Canvas.Font.Name := FFont.Name;
  FMeasure.Canvas.Font.Height := FFont.Height;
  FMeasure.Canvas.Font.Style := FFont.Style;
  FMeasure.Canvas.Font.Quality := fqAntialiased;
end;

function TGLCanvas.FontKey: string;
begin
  Result := FFont.Name + '|' + IntToStr(FFont.Height) + '|' + IntToStr(Byte(FFont.Style)) + '|';
end;

function TGLCanvas.TextWidth(const S: string): Integer;
var
  key: string;
begin
  if S = '' then Exit(0);
  key := FontKey + S;
  if FWidthCache.TryGetValue(key, Result) then Exit;
  ApplyMeasureFont;
  Result := FMeasure.Canvas.TextWidth(S);
  FWidthCache.Add(key, Result);
end;

function TGLCanvas.TextHeight(const S: string): Integer;
begin
  ApplyMeasureFont;
  if S = '' then Result := FMeasure.Canvas.TextHeight('Ag')
  else Result := FMeasure.Canvas.TextHeight(S);
end;

function TGLCanvas.TextTexture(const AText: string): TGLTextEntry;
var
  key: string;
  bmp: TBitmap;
  w, h, x, y: Integer;
  px: TArray<Byte>;
  row: PByteArray;
  tex: Cardinal;
begin
  key := FontKey + AText;
  if FTextCache.TryGetValue(key, Result) then
  begin
    Result.LastFrame := FFrame;
    FTextCache[key] := Result;
    Exit;
  end;
  ApplyMeasureFont;
  w := FMeasure.Canvas.TextWidth(AText) + 2;
  h := FMeasure.Canvas.TextHeight(AText);
  bmp := TBitmap.Create;
  try
    bmp.PixelFormat := pf24bit;
    bmp.SetSize(w, h);
    bmp.Canvas.Brush.Color := clBlack;
    bmp.Canvas.FillRect(Rect(0, 0, w, h));
    bmp.Canvas.Font.Name := FFont.Name;
    bmp.Canvas.Font.Height := FFont.Height;
    bmp.Canvas.Font.Style := FFont.Style;
    bmp.Canvas.Font.Quality := fqAntialiased;
    bmp.Canvas.Font.Color := clWhite;
    bmp.Canvas.Brush.Style := bsClear;
    bmp.Canvas.TextOut(0, 0, AText);
    SetLength(px, w * h);
    for y := 0 to h - 1 do
    begin
      row := bmp.ScanLine[y];
      for x := 0 to w - 1 do
        px[y * w + x] := row[x * 3 + 1];
    end;
  finally
    bmp.Free;
  end;
  glGenTextures(1, @tex);
  glBindTexture(GL_TEXTURE_2D, tex);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, w, h, 0, GL_RED, GL_UNSIGNED_BYTE, @px[0]);
  Result.Tex := tex;
  Result.W := w;
  Result.H := h;
  Result.LastFrame := FFrame;
  FTextCache.Add(key, Result);
end;

procedure TGLCanvas.TextOut(X, Y: Integer; const S: string);
var
  e: TGLTextEntry;
  rgb: Integer;
begin
  if FRec <> nil then
  begin
    if S <> '' then FRec.Text(X, Y, S, FFont.Name, Abs(FFont.Height), FFont.Style, FFont.Color, TextHeight(S));
    Exit;
  end;
  if (S = '') or FClipEmpty or not FReady then Exit;
  e := TextTexture(S);
  rgb := ColorToRGB(FFont.Color);
  AddQuad(X, Y, X + e.W, Y, X + e.W, Y + e.H, X, Y + e.H, rgb, 1, e.Tex, 0, 0, 1, 1);
end;

procedure TGLCanvas.TextOutVertical(X, Y: Integer; const S: string);
var
  e: TGLTextEntry;
  rgb: Integer;
begin
  if (S = '') or FClipEmpty or not FReady then Exit;
  e := TextTexture(S);
  rgb := ColorToRGB(FFont.Color);
  AddQuad(X, Y + e.W, X, Y, X + e.H, Y, X + e.H, Y + e.W, rgb, 1, e.Tex, 0, 0, 1, 1);
end;

procedure TGLCanvas.TextRect(const R: TRect; X, Y: Integer; const S: string);
begin
  PushClip(R);
  try
    TextOut(X, Y, S);
  finally
    PopClip;
  end;
end;

procedure TGLCanvas.SetPixel(X, Y: Integer; AColor: TColor);
begin
  Solid(X, Y, X + 1, Y + 1, AColor);
end;

procedure TGLCanvas.Draw(X, Y: Integer; ABitmap: TBitmap);
begin
  if (ABitmap = nil) or ABitmap.Empty then Exit;
  StretchDraw(Rect(X, Y, X + ABitmap.Width, Y + ABitmap.Height), ABitmap);
end;

procedure TGLCanvas.StretchDraw(const R: TRect; ABitmap: TBitmap);
var
  tmp: TBitmap;
  w, h, yy: Integer;
  px: TArray<Byte>;
  tex: Cardinal;
begin
  if (ABitmap = nil) or ABitmap.Empty or FClipEmpty or not FReady then Exit;
  w := ABitmap.Width;
  h := ABitmap.Height;
  tmp := TBitmap.Create;
  try
    tmp.PixelFormat := pf32bit;
    tmp.SetSize(w, h);
    tmp.Canvas.Draw(0, 0, ABitmap);
    SetLength(px, w * h * 4);
    for yy := 0 to h - 1 do
      Move(tmp.ScanLine[yy]^, px[yy * w * 4], w * 4);
  finally
    tmp.Free;
  end;
  glGenTextures(1, @tex);
  glBindTexture(GL_TEXTURE_2D, tex);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_BGRA, GL_UNSIGNED_BYTE, @px[0]);
  FTransient.Add(tex);
  AddQuad(R.Left, R.Top, R.Right, R.Top, R.Right, R.Bottom, R.Left, R.Bottom, clWhite, 2, tex, 0, 0, 1, 1);
end;

{ ---- TGLView ---- }

type
  { one hidden window + GL 3.3 context + canvas + framebuffer used by every
    TGLView with SharedSurface = True }
  TGLSharedHost = class
  public
    Wnd: HWND;
    DC: HDC;
    RC: HGLRC;
    Canvas: TGLCanvas;
    Fbo, Rbo: Cardinal;
    W, H: Integer;
    Failure: string;
    Tried: Boolean;
    function Ready: Boolean;
    procedure Setup;
    function EnsureTarget(AW, AH: Integer): Boolean;
    procedure Teardown;
  end;

var
  SharedHost: TGLSharedHost;

function Host: TGLSharedHost;
begin
  if SharedHost = nil then SharedHost := TGLSharedHost.Create;
  if not SharedHost.Tried then SharedHost.Setup;
  Result := SharedHost;
end;

function TGLSharedHost.Ready: Boolean;
begin
  Result := (RC <> 0) and Assigned(Canvas) and Canvas.Ready;
end;

procedure TGLSharedHost.Setup;
begin
  Tried := True;
  if not InitOpenGL then
  begin
    Failure := 'opengl32.dll could not be loaded';
    Exit;
  end;
  Wnd := CreateWindowEx(WS_EX_TOOLWINDOW, 'STATIC', 'UDAWGLHost', WS_POPUP, 0, 0, 1, 1, 0, 0, HInstance, nil);
  if Wnd = 0 then
  begin
    Failure := 'the shared GL window could not be created';
    Exit;
  end;
  DC := GetDC(Wnd);
  RC := CreateRenderingContextVersion(DC, [opDoubleBuffered], 3, 3, True, 32, 0, 0, 0, 0, 0);
  if RC = 0 then
  begin
    Failure := 'the graphics driver does not provide an OpenGL 3.3 core context';
    Exit;
  end;
  ActivateRenderingContext(DC, RC);
  Canvas := TGLCanvas.Create;
  if not Canvas.Initialize then
    Failure := 'OpenGL 3.3 shader initialisation failed';
  DeactivateRenderingContext;
end;

{ ---- the driver's report ---- }

function GLStrOf(AName: Cardinal): string;
var
  p: PAnsiChar;
begin
  p := PAnsiChar(glGetString(AName));
  if p = nil then Result := '' else Result := string(AnsiString(p));
end;

function GLDriverReport: TArray<string>;
const
  GL_GPU_MEM_INFO_DEDICATED_VIDMEM_NVX = $9047;
  GL_GPU_MEM_INFO_TOTAL_AVAILABLE_MEM_NVX = $9048;
  GL_GPU_MEM_INFO_CURRENT_AVAILABLE_VIDMEM_NVX = $9049;
  GL_GPU_MEM_INFO_EVICTION_COUNT_NVX = $904A;
  GL_GPU_MEM_INFO_EVICTED_MEMORY_NVX = $904B;
  GL_VBO_FREE_MEMORY_ATI = $87FB;
  GL_TEXTURE_FREE_MEMORY_ATI = $87FC;
var
  h: TGLSharedHost;
  list: TStringList;
  exts: TStringList;
  i, n: Integer;
  v: array[0..3] of GLint;
  e: PAnsiChar;
  ext: string;

  procedure Add(const K, V: string);
  begin
    list.Add(K + '|' + V);
  end;

  function IntOf(AName: Cardinal): Integer;
  begin
    v[0] := 0;
    glGetIntegerv(AName, @v[0]);
    Result := v[0];
  end;

  function Has(const AName: string): Boolean;
  begin
    Result := exts.IndexOf(AName) >= 0;
  end;

  function Mb(AKb: Integer): string;
  begin
    Result := Format('%.1f MB (%d KB)', [AKb / 1024, AKb]);
  end;

begin
  h := Host;
  if not h.Ready then
  begin
    SetLength(Result, 1);
    Result[0] := 'status|OpenGL 3.3 is not available: ' + h.Failure;
    Exit;
  end;
  list := TStringList.Create;
  exts := TStringList.Create;
  try
    exts.Sorted := True;
    exts.Duplicates := dupIgnore;
    wglMakeCurrent(h.DC, h.RC);
    try
      Add('vendor', GLStrOf(GL_VENDOR));
      Add('renderer', GLStrOf(GL_RENDERER));
      Add('version', GLStrOf(GL_VERSION));
      Add('shading language', GLStrOf(GL_SHADING_LANGUAGE_VERSION));
      Add('context', Format('%d.%d, %s profile', [IntOf(GL_MAJOR_VERSION), IntOf(GL_MINOR_VERSION),
        IfThen((IntOf(GL_CONTEXT_PROFILE_MASK) and GL_CONTEXT_CORE_PROFILE_BIT) <> 0, 'core', 'compatibility')]));
      n := IntOf(GL_NUM_EXTENSIONS);
      for i := 0 to n - 1 do
      begin
        e := PAnsiChar(glGetStringi(GL_EXTENSIONS, i));
        if e <> nil then exts.Add(string(AnsiString(e)));
      end;
      Add('max texture size', Format('%d x %d', [IntOf(GL_MAX_TEXTURE_SIZE), IntOf(GL_MAX_TEXTURE_SIZE)]));
      Add('max 3D texture size', IntToStr(IntOf(GL_MAX_3D_TEXTURE_SIZE)));
      Add('max array texture layers', IntToStr(IntOf(GL_MAX_ARRAY_TEXTURE_LAYERS)));
      Add('max renderbuffer size', IntToStr(IntOf(GL_MAX_RENDERBUFFER_SIZE)));
      glGetIntegerv(GL_MAX_VIEWPORT_DIMS, @v[0]);
      Add('max viewport', Format('%d x %d', [v[0], v[1]]));
      Add('max combined texture units', IntToStr(IntOf(GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS)));
      Add('max fragment texture units', IntToStr(IntOf(GL_MAX_TEXTURE_IMAGE_UNITS)));
      Add('max vertex attributes', IntToStr(IntOf(GL_MAX_VERTEX_ATTRIBS)));
      Add('max draw buffers', IntToStr(IntOf(GL_MAX_DRAW_BUFFERS)));
      Add('max colour attachments', IntToStr(IntOf(GL_MAX_COLOR_ATTACHMENTS)));
      Add('max multisample samples', IntToStr(IntOf(GL_MAX_SAMPLES)));
      Add('max uniform block size', IntToStr(IntOf(GL_MAX_UNIFORM_BLOCK_SIZE)));
      Add('max vertex uniform components', IntToStr(IntOf(GL_MAX_VERTEX_UNIFORM_COMPONENTS)));
      Add('max fragment uniform components', IntToStr(IntOf(GL_MAX_FRAGMENT_UNIFORM_COMPONENTS)));
      Add('extensions', IntToStr(exts.Count));
      { video memory, as far as the driver says: NVIDIA and AMD report it through their own extensions }
      if Has('GL_NVX_gpu_memory_info') then
      begin
        Add('GPU dedicated memory (NVX)', Mb(IntOf(GL_GPU_MEM_INFO_DEDICATED_VIDMEM_NVX)));
        Add('GPU total available memory (NVX)', Mb(IntOf(GL_GPU_MEM_INFO_TOTAL_AVAILABLE_MEM_NVX)));
        Add('GPU memory free now (NVX)', Mb(IntOf(GL_GPU_MEM_INFO_CURRENT_AVAILABLE_VIDMEM_NVX)));
        Add('GPU evictions (NVX)', IntToStr(IntOf(GL_GPU_MEM_INFO_EVICTION_COUNT_NVX)));
        Add('GPU evicted memory (NVX)', Mb(IntOf(GL_GPU_MEM_INFO_EVICTED_MEMORY_NVX)));
      end;
      if Has('GL_ATI_meminfo') then
      begin
        FillChar(v, SizeOf(v), 0);
        glGetIntegerv(GL_VBO_FREE_MEMORY_ATI, @v[0]);
        Add('GPU free memory - buffers (ATI)', Mb(v[0]));
        FillChar(v, SizeOf(v), 0);
        glGetIntegerv(GL_TEXTURE_FREE_MEMORY_ATI, @v[0]);
        Add('GPU free memory - textures (ATI)', Mb(v[0]));
      end;
      if not (Has('GL_NVX_gpu_memory_info') or Has('GL_ATI_meminfo')) then
        Add('GPU memory (driver)', 'this driver does not report video memory through OpenGL - see the adapter list');
      glGetError;   // forget any error the optional queries above may have raised
    finally
      wglMakeCurrent(0, 0);
    end;
    for i := 0 to exts.Count - 1 do
    begin
      ext := exts[i];
      list.Add('extension|' + ext);
    end;
    Result := list.ToStringArray;
  finally
    exts.Free;
    list.Free;
  end;
end;

{ the framebuffer only ever grows; a view renders into its bottom-left corner }
function TGLSharedHost.EnsureTarget(AW, AH: Integer): Boolean;
var
  nw, nh: Integer;
begin
  if (Fbo <> 0) and (AW <= W) and (AH <= H) then Exit(True);
  nw := Max(AW, W);
  nh := Max(AH, H);
  if Fbo <> 0 then glDeleteFramebuffers(1, @Fbo);
  if Rbo <> 0 then glDeleteRenderbuffers(1, @Rbo);
  Fbo := 0;
  Rbo := 0;
  glGenFramebuffers(1, @Fbo);
  glGenRenderbuffers(1, @Rbo);
  glBindRenderbuffer(GL_RENDERBUFFER, Rbo);
  glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, nw, nh);
  glBindFramebuffer(GL_FRAMEBUFFER, Fbo);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, Rbo);
  Result := glCheckFramebufferStatus(GL_FRAMEBUFFER) = GL_FRAMEBUFFER_COMPLETE;
  if Result then
  begin
    W := nw;
    H := nh;
  end
  else
  begin
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glDeleteFramebuffers(1, @Fbo);
    glDeleteRenderbuffers(1, @Rbo);
    Fbo := 0;
    Rbo := 0;
  end;
end;

procedure TGLSharedHost.Teardown;
begin
  if RC <> 0 then
  begin
    wglMakeCurrent(DC, RC);
    if Fbo <> 0 then glDeleteFramebuffers(1, @Fbo);
    if Rbo <> 0 then glDeleteRenderbuffers(1, @Rbo);
    if Assigned(Canvas) then Canvas.Release;
    DeactivateRenderingContext;
    DestroyRenderingContext(RC);
    RC := 0;
  end;
  FreeAndNil(Canvas);
  if (DC <> 0) and (Wnd <> 0) then ReleaseDC(Wnd, DC);
  if Wnd <> 0 then DestroyWindow(Wnd);
  DC := 0;
  Wnd := 0;
end;

constructor TGLView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  FGL := TGLCanvas.Create;
  FFrameBmp := TBitmap.Create;
  FFrameBmp.PixelFormat := pf32bit;
  Width := 200;
  Height := 150;
end;

destructor TGLView.Destroy;
begin
  ReleaseContext;
  FFrameBmp.Free;
  FGL.Free;
  inherited Destroy;
end;

procedure TGLView.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  Params.Style := Params.Style or WS_CLIPCHILDREN or WS_CLIPSIBLINGS;
  Params.WindowClass.style := Params.WindowClass.style or CS_OWNDC;
end;

procedure TGLView.CreateWnd;
begin
  inherited CreateWnd;
  FFailure := '';
  DragAcceptFiles(Handle, True);
  if csDesigning in ComponentState then Exit;
  if FShared then
  begin
    FFailure := Host.Failure;
    Exit;
  end;
  if not InitOpenGL then
  begin
    FFailure := 'opengl32.dll could not be loaded';
    Exit;
  end;
  FDC := GetDC(Handle);
  FRC := CreateRenderingContextVersion(FDC, [opDoubleBuffered], 3, 3, True,
    32, 0, 0, 0, 0, 0);
  if FRC = 0 then
  begin
    FFailure := 'the graphics driver does not provide an OpenGL 3.3 core context';
    Exit;
  end;
  ActivateRenderingContext(FDC, FRC);
  if not FGL.Initialize then
  begin
    FFailure := 'OpenGL 3.3 shader initialisation failed';
    DeactivateRenderingContext;
    Exit;
  end;
  DeactivateRenderingContext;
end;

procedure TGLView.ReleaseTarget;
begin
  if FFbo <> 0 then glDeleteFramebuffers(1, @FFbo);
  if FRbo <> 0 then glDeleteRenderbuffers(1, @FRbo);
  FFbo := 0;
  FRbo := 0;
  FTargetW := 0;
  FTargetH := 0;
end;

{ The scene is rendered into an off-screen framebuffer and read back into a DIB
  that the VCL blits, rather than presented through the window's own swap chain.
  A form with DoubleBuffered = True is WS_EX_COMPOSITED, which captures child
  windows into a bitmap and shows a native OpenGL surface as blank; going
  through the VCL canvas works under that and keeps the flicker-free,
  fully-owned-client-area behaviour. }
function TGLView.EnsureTarget(AW, AH: Integer): Boolean;
begin
  if (FFbo <> 0) and (FTargetW = AW) and (FTargetH = AH) then Exit(True);
  ReleaseTarget;
  glGenFramebuffers(1, @FFbo);
  glGenRenderbuffers(1, @FRbo);
  glBindRenderbuffer(GL_RENDERBUFFER, FRbo);
  glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, AW, AH);
  glBindFramebuffer(GL_FRAMEBUFFER, FFbo);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, FRbo);
  Result := glCheckFramebufferStatus(GL_FRAMEBUFFER) = GL_FRAMEBUFFER_COMPLETE;
  if not Result then
  begin
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    ReleaseTarget;
    Exit;
  end;
  FTargetW := AW;
  FTargetH := AH;
  FFrameBmp.SetSize(AW, AH);
end;

function TGLView.GetGL: TGLCanvas;
begin
  if FShared then Result := Host.Canvas else Result := FGL;
end;

function TGLView.GLReady: Boolean;
begin
  if FShared then Result := Host.Ready
  else Result := (FRC <> 0) and FGL.Ready;
end;

procedure TGLView.ReleaseContext;
begin
  if FRC <> 0 then
  begin
    wglMakeCurrent(FDC, FRC);
    ReleaseTarget;
    FGL.Release;
    DeactivateRenderingContext;
    DestroyRenderingContext(FRC);
    FRC := 0;
  end;
  if (FDC <> 0) and HandleAllocated then ReleaseDC(Handle, FDC);
  FDC := 0;
end;

procedure TGLView.DestroyWnd;
begin
  ReleaseContext;
  inherited DestroyWnd;
end;

procedure TGLView.WMDropFiles(var Msg: TWMDropFiles);
var
  pt: TPoint;
begin
  if Assigned(FOnDropFiles) then
  begin
    DragQueryPoint(Msg.Drop, pt);
    FOnDropFiles(Self, Msg.Drop, pt);
  end
  else
    DragFinish(Msg.Drop);
  Msg.Result := 0;
end;

procedure TGLView.WMContextMenu(var Msg: TWMContextMenu);
var
  pt: TPoint;
begin
  if Assigned(GLContextMenuHandler) and (PopupMenu <> nil) and PopupMenu.AutoPopup and
     not (csDesigning in ComponentState) then
  begin
    pt := Point(Msg.XPos, Msg.YPos);
    if (pt.X = -1) and (pt.Y = -1) then pt := ClientToScreen(Point(Width shr 1, Height shr 1));
    GLContextMenuHandler(Self, PopupMenu, pt.X, pt.Y);
    Msg.Result := 1;
  end
  else inherited;
end;

procedure TGLView.WMGetDlgCode(var Msg: TWMGetDlgCode);
begin
  inherited;
  if FWantArrows then Msg.Result := Msg.Result or DLGC_WANTARROWS;
end;

procedure TGLView.WMEraseBkgnd(var Msg: TWMEraseBkgnd);
begin
  Msg.Result := 1;
end;

procedure TGLView.PaintGL;
begin
  if Assigned(FOnPaint) then FOnPaint(Self);
end;

procedure TGLView.PrepareCanvas(ACanvas: TGLCanvas);
begin
end;

procedure TGLView.PaintShared;
var
  h: TGLSharedHost;
begin
  h := Host;
  if (ClientWidth <= 0) or (ClientHeight <= 0) then Exit;
  wglMakeCurrent(h.DC, h.RC);
  try
    if not h.EnsureTarget(ClientWidth, ClientHeight) then Exit;
    if (FFrameBmp.Width <> ClientWidth) or (FFrameBmp.Height <> ClientHeight) then
      FFrameBmp.SetSize(ClientWidth, ClientHeight);
    glBindFramebuffer(GL_FRAMEBUFFER, h.Fbo);
    h.Canvas.ResetState;
    PrepareCanvas(h.Canvas);
    h.Canvas.BeginFrame(ClientWidth, ClientHeight);
    PaintGL;
    h.Canvas.EndFrame;
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, ClientWidth, ClientHeight, GL_BGRA, GL_UNSIGNED_BYTE,
      FFrameBmp.ScanLine[ClientHeight - 1]);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
  finally
    wglMakeCurrent(0, 0);
  end;
  Canvas.Draw(0, 0, FFrameBmp);
  GLNoteFrame(Self);
end;

procedure TGLView.Paint;
var
  msg: string;
begin
  if FShared and not (csDesigning in ComponentState) and Host.Ready then
  begin
    PaintShared;
    Exit;
  end;
  if FShared then
  begin
    Canvas.Brush.Color := clBlack;
    Canvas.FillRect(ClientRect);
    Exit;
  end;
  if (FRC = 0) or not FGL.Ready then
  begin
    Canvas.Brush.Color := clBlack;
    Canvas.FillRect(ClientRect);
    Canvas.Font.Color := clSilver;
    msg := 'OpenGL 3.3 is required for this view';
    if FFailure <> '' then msg := msg + ': ' + FFailure;
    if not (csDesigning in ComponentState) or (FFailure <> '') then
      Canvas.TextOut(8, 8, msg)
    else
      Canvas.TextOut(8, 8, Name);
    Exit;
  end;
  if (ClientWidth <= 0) or (ClientHeight <= 0) then Exit;
  wglMakeCurrent(FDC, FRC);
  try
    if not EnsureTarget(ClientWidth, ClientHeight) then Exit;
    glBindFramebuffer(GL_FRAMEBUFFER, FFbo);
    FGL.BeginFrame(ClientWidth, ClientHeight);
    PaintGL;
    FGL.EndFrame;
    { a bottom-up 32-bit DIB stores its last scan line first, which is the
      row order glReadPixels returns }
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, FTargetW, FTargetH, GL_BGRA, GL_UNSIGNED_BYTE,
      FFrameBmp.ScanLine[FTargetH - 1]);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
  finally
    wglMakeCurrent(0, 0);
  end;
  Canvas.Draw(0, 0, FFrameBmp);
  GLNoteFrame(Self);
end;

initialization

finalization
  FreeAndNil(GFrameCounts);
  if Assigned(SharedHost) then
  begin
    SharedHost.Teardown;
    FreeAndNil(SharedHost);
  end;

end.
