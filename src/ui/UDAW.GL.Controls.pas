unit UDAW.GL.Controls;

{ Small OpenGL-rendered controls built on TGLView.

  TGLIconBar is a strip of compact icon buttons drawn on one GL surface (so a
  whole toolbar costs one context, not one per button): each button is a
  vector icon, with hover / pressed / active states and a tooltip. It replaces
  rows of wide captioned buttons with MorningDAW-style icon tools.

  Published at design time:
    Buttons       icon ids separated by ';'  (mixer;piano;tracker;record;hide)
    Hints         tooltip texts, same order, separated by ';'
    ActiveIndex   the highlighted ("on") button, -1 for none
    CellWidth     width of one button cell
    OnButtonClick (Sender, AIndex, AId)

  Icon ids: mixer, piano, tracker, record, ai, hide, back, play, stop, loop,
  add, scene, minus, clone, trash, deletecache, save, saveas, load, place, fill, euclid, random,
  clear, addrow, delrow, select, range, split, erase, export, tools, undo, redo, zoomin,
  zoomout, left, right, selall, zoomsel, fit, trim, cut, silence, reverse, normalize, fadein,
  fadeout, gain, extend, stretch, ok, pause, mute, fx, up, newfolder, totimeline. Unknown ids draw a plain square. }

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes,
  System.Types, System.UITypes, Vcl.Controls, Vcl.Graphics, Vcl.Forms,
  Vcl.Themes, UDAW.GL.Canvas;

type
  TGLIconClickEvent = procedure(Sender: TObject; AIndex: Integer; const AId: string) of object;

  TGLIconBar = class(TGLView)
  private
    FIds: TStringList;
    FHintTexts: TStringList;
    FDisabled: TArray<Boolean>;
    FActive: Integer;
    FLit: Integer;
    FHover: Integer;
    FPressed: Integer;
    FCellWidth: Integer;
    FTransparent: Boolean;
    FOnButtonClick: TGLIconClickEvent;
    function GetButtons: string;
    procedure SetButtons(const AValue: string);
    function GetHints: string;
    procedure SetHints(const AValue: string);
    procedure SetActive(AValue: Integer);
    procedure SetLit(AValue: Integer);
    function IsLit(AIndex: Integer): Boolean;
    procedure SetCellWidth(AValue: Integer);
    function IndexAt(X, Y: Integer): Integer;
    function CellRect(AIndex: Integer): TRect;
    procedure UpdateHover(AIndex: Integer);
    procedure CMMouseLeave(var Msg: TMessage); message CM_MOUSELEAVE;
  protected
    procedure PaintGL; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetButtonEnabled(AIndex: Integer; AEnabled: Boolean);
    { draws one of the bar's vector icons (inside a 16x16 box centred in R); used by the menus too }
    class procedure DrawIcon(cv: TGLCanvas; const AId: string; const R: TRect; AColor: TColor);
  published
    { the bar takes the colour of whatever it sits on (a form painting its own background) instead of the face colour }
    property Transparent: Boolean read FTransparent write FTransparent default False;
    property Buttons: string read GetButtons write SetButtons;
    property Hints: string read GetHints write SetHints;
    property ActiveIndex: Integer read FActive write SetActive default -1;
    { bit i set: button i is drawn lit (a toggle that is on - loop, metronome ...),
      alongside the single ActiveIndex }
    property LitMask: Integer read FLit write SetLit default 0;
    property CellWidth: Integer read FCellWidth write SetCellWidth default 30;
    property OnButtonClick: TGLIconClickEvent read FOnButtonClick write FOnButtonClick;
  end;

implementation

uses
  System.Math;

function Sys(AColor: TColor): TColor;
begin
  Result := ColorToRGB(StyleServices.GetSystemColor(AColor));
end;

function Blend(A, B: TColor; T: Double): TColor;
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

constructor TGLIconBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FIds := TStringList.Create;
  FHintTexts := TStringList.Create;
  FActive := -1;
  FHover := -1;
  FPressed := -1;
  FCellWidth := 30;
  Width := 150;
  Height := 28;
end;

destructor TGLIconBar.Destroy;
begin
  FHintTexts.Free;
  FIds.Free;
  inherited Destroy;
end;

function TGLIconBar.GetButtons: string;
begin
  Result := StringReplace(Trim(FIds.Text), sLineBreak, ';', [rfReplaceAll]);
end;

procedure TGLIconBar.SetButtons(const AValue: string);
begin
  FIds.Text := StringReplace(AValue, ';', sLineBreak, [rfReplaceAll]);
  SetLength(FDisabled, FIds.Count);
  Invalidate;
end;

function TGLIconBar.GetHints: string;
begin
  Result := StringReplace(Trim(FHintTexts.Text), sLineBreak, ';', [rfReplaceAll]);
end;

procedure TGLIconBar.SetHints(const AValue: string);
begin
  FHintTexts.Text := StringReplace(AValue, ';', sLineBreak, [rfReplaceAll]);
end;

procedure TGLIconBar.SetActive(AValue: Integer);
begin
  if FActive = AValue then Exit;
  FActive := AValue;
  Invalidate;
end;

procedure TGLIconBar.SetCellWidth(AValue: Integer);
begin
  if AValue < 16 then AValue := 16;
  FCellWidth := AValue;
  Invalidate;
end;

procedure TGLIconBar.SetButtonEnabled(AIndex: Integer; AEnabled: Boolean);
begin
  if (AIndex < 0) or (AIndex >= Length(FDisabled)) then Exit;
  if FDisabled[AIndex] = (not AEnabled) then Exit;
  FDisabled[AIndex] := not AEnabled;
  Invalidate;
end;

function TGLIconBar.CellRect(AIndex: Integer): TRect;
begin
  Result := Rect(2 + AIndex * FCellWidth, 2, 2 + (AIndex + 1) * FCellWidth - 2, Height - 2);
end;

function TGLIconBar.IndexAt(X, Y: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to FIds.Count - 1 do
    if PtInRect(CellRect(i), Point(X, Y)) then Exit(i);
  Result := -1;
end;

procedure TGLIconBar.UpdateHover(AIndex: Integer);
begin
  if AIndex = FHover then Exit;
  FHover := AIndex;
  if (AIndex >= 0) and (AIndex < FHintTexts.Count) then Hint := FHintTexts[AIndex]
  else Hint := '';
  Application.CancelHint;
  Invalidate;
end;

procedure TGLIconBar.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseMove(Shift, X, Y);
  UpdateHover(IndexAt(X, Y));
end;

procedure TGLIconBar.CMMouseLeave(var Msg: TMessage);
begin
  inherited;
  UpdateHover(-1);
  FPressed := -1;
end;

procedure TGLIconBar.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;
  FPressed := IndexAt(X, Y);
  if (FPressed >= 0) and (FPressed < Length(FDisabled)) and FDisabled[FPressed] then FPressed := -1;
  Invalidate;
end;

procedure TGLIconBar.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  idx: Integer;
begin
  inherited MouseUp(Button, Shift, X, Y);
  idx := IndexAt(X, Y);
  if (Button = mbLeft) and (FPressed >= 0) and (idx = FPressed) and Assigned(FOnButtonClick) then
  begin
    FPressed := -1;
    FOnButtonClick(Self, idx, FIds[idx]);
  end;
  FPressed := -1;
  Invalidate;
end;

{ vector icons, drawn inside a 16x16 box centred in R }
class procedure TGLIconBar.DrawIcon(cv: TGLCanvas; const AId: string; const R: TRect; AColor: TColor);
var
  x, y, k: Integer;
begin
  x := (R.Left + R.Right) div 2 - 8;
  y := (R.Top + R.Bottom) div 2 - 8;
  cv.Pen.Style := psSolid;
  cv.Pen.Width := 1;
  cv.Pen.Color := AColor;
  cv.Brush.Style := bsSolid;
  cv.Brush.Color := AColor;
  if AId = 'mixer' then
  begin
    for k := 0 to 2 do
    begin
      cv.MoveTo(x + 2 + k * 5, y + 1); cv.LineTo(x + 2 + k * 5, y + 15);
      cv.FillRect(Rect(x + k * 5, y + 3 + ((k * 5) mod 8), x + 5 + k * 5, y + 6 + ((k * 5) mod 8)));
    end;
  end
  else if AId = 'piano' then
  begin
    cv.Brush.Style := bsClear;
    cv.Rectangle(x, y + 2, x + 16, y + 14);
    cv.Brush.Style := bsSolid;
    for k := 1 to 3 do
    begin
      cv.MoveTo(x + k * 4, y + 8); cv.LineTo(x + k * 4, y + 14);
    end;
    for k := 0 to 2 do
      cv.FillRect(Rect(x + 3 + k * 4, y + 2, x + 6 + k * 4, y + 9));
  end
  else if AId = 'tracker' then
  begin
    for k := 0 to 3 do
    begin
      cv.MoveTo(x, y + 2 + k * 4); cv.LineTo(x + 16, y + 2 + k * 4);
    end;
    cv.MoveTo(x + 1, y + 2); cv.LineTo(x + 1, y + 14);
    cv.MoveTo(x + 9, y + 2); cv.LineTo(x + 9, y + 14);
    cv.FillRect(Rect(x + 3, y + 3, x + 7, y + 5));
    cv.FillRect(Rect(x + 11, y + 7, x + 15, y + 9));
  end
  else if AId = 'record' then
  begin
    cv.Brush.Color := $004040E0;
    cv.Pen.Color := $004040E0;
    cv.Ellipse(x + 2, y + 2, x + 14, y + 14);
  end
  else if AId = 'hide' then
  begin
    cv.Pen.Width := 2;
    cv.MoveTo(x + 2, y + 5); cv.LineTo(x + 8, y + 11);
    cv.LineTo(x + 14, y + 5);
    cv.Pen.Width := 1;
    cv.FillRect(Rect(x + 2, y + 13, x + 14, y + 15));
  end
  else if AId = 'back' then
  begin
    cv.Pen.Width := 2;
    cv.MoveTo(x + 13, y + 12); cv.LineTo(x + 13, y + 7);
    cv.LineTo(x + 5, y + 7);
    cv.Pen.Width := 1;
    cv.Polygon([Point(x + 1, y + 7), Point(x + 7, y + 2), Point(x + 7, y + 12)]);
  end
  else if AId = 'play' then
    cv.Polygon([Point(x + 3, y + 1), Point(x + 3, y + 15), Point(x + 14, y + 8)])
  else if AId = 'playpat' then
  begin
    { a play triangle with a loop arrow running round beneath it: one pattern, over and over }
    cv.Polygon([Point(x + 2, y + 1), Point(x + 2, y + 9), Point(x + 9, y + 5)]);
    cv.Pen.Width := 2;
    cv.MoveTo(x + 2, y + 11); cv.LineTo(x + 2, y + 14);
    cv.LineTo(x + 13, y + 14); cv.LineTo(x + 13, y + 9);
    cv.Pen.Width := 1;
    cv.Polygon([Point(x + 10, y + 9), Point(x + 16, y + 9), Point(x + 13, y + 4)]);
  end
  else if AId = 'stop' then
    cv.FillRect(Rect(x + 3, y + 3, x + 13, y + 13))
  else if AId = 'video' then
  begin
    { a film frame with a play triangle }
    cv.Brush.Style := bsClear;
    cv.Rectangle(x + 1, y + 2, x + 15, y + 14);
    cv.Brush.Style := bsSolid;
    cv.FillRect(Rect(x + 1, y + 4, x + 3, y + 6));
    cv.FillRect(Rect(x + 1, y + 9, x + 3, y + 11));
    cv.FillRect(Rect(x + 13, y + 4, x + 15, y + 6));
    cv.FillRect(Rect(x + 13, y + 9, x + 15, y + 11));
    cv.Polygon([Point(x + 6, y + 5), Point(x + 6, y + 11), Point(x + 11, y + 8)]);
  end
  else if AId = 'editor' then
  begin
    { the arrangement above, an editor pane below it }
    cv.Brush.Style := bsClear;
    cv.Rectangle(x + 1, y + 2, x + 15, y + 14);
    cv.Brush.Style := bsSolid;
    cv.FillRect(Rect(x + 2, y + 9, x + 14, y + 13));
    cv.MoveTo(x + 1, y + 8); cv.LineTo(x + 15, y + 8);
  end
  else if AId = 'stage' then
  begin
    { a launcher grid: clips as pads }
    cv.FillRect(Rect(x + 1, y + 2, x + 7, y + 7));
    cv.FillRect(Rect(x + 9, y + 2, x + 15, y + 7));
    cv.FillRect(Rect(x + 1, y + 9, x + 7, y + 14));
    cv.FillRect(Rect(x + 9, y + 9, x + 15, y + 14));
  end
  else if AId = 'browser' then
  begin
    { a folder tree: nested lines with nodes }
    cv.FillRect(Rect(x + 1, y + 2, x + 5, y + 5));
    cv.FillRect(Rect(x + 5, y + 6, x + 9, y + 9));
    cv.FillRect(Rect(x + 5, y + 11, x + 9, y + 14));
    cv.MoveTo(x + 2, y + 5); cv.LineTo(x + 2, y + 12); cv.LineTo(x + 5, y + 12);
    cv.MoveTo(x + 2, y + 7); cv.LineTo(x + 5, y + 7);
    cv.FillRect(Rect(x + 10, y + 7, x + 15, y + 8));
    cv.FillRect(Rect(x + 10, y + 12, x + 15, y + 13));
  end
  else if AId = 'metronome' then
  begin
    { a metronome: tapered body with a swinging arm }
    cv.Brush.Style := bsClear;
    cv.Polygon([Point(x + 6, y + 2), Point(x + 10, y + 2), Point(x + 14, y + 14), Point(x + 2, y + 14)]);
    cv.Brush.Style := bsSolid;
    cv.Pen.Width := 2;
    cv.MoveTo(x + 8, y + 12); cv.LineTo(x + 11, y + 4);
    cv.Pen.Width := 1;
    cv.FillRect(Rect(x + 10, y + 5, x + 13, y + 7));
  end
  else if AId = 'lanes' then
  begin
    { the lane stack: three stacked lanes with a marker, a step line and a bar }
    cv.FillRect(Rect(x + 1, y + 2, x + 15, y + 5));
    cv.FillRect(Rect(x + 1, y + 7, x + 6, y + 8));
    cv.FillRect(Rect(x + 6, y + 6, x + 10, y + 8));
    cv.FillRect(Rect(x + 10, y + 7, x + 15, y + 8));
    cv.FillRect(Rect(x + 1, y + 11, x + 15, y + 14));
  end
  else if AId = 'chords' then
  begin
    { chord chips: two blocks of different length with a stem }
    cv.FillRect(Rect(x + 1, y + 3, x + 8, y + 8));
    cv.FillRect(Rect(x + 9, y + 3, x + 15, y + 8));
    cv.FillRect(Rect(x + 3, y + 10, x + 5, y + 14));
    cv.FillRect(Rect(x + 7, y + 10, x + 9, y + 14));
    cv.FillRect(Rect(x + 11, y + 10, x + 13, y + 14));
  end
  else if AId = 'foley' then
  begin
    { a sound pad struck, with level bars rising beside it: the Foley sampler }
    cv.Brush.Style := bsClear;
    cv.Rectangle(x + 1, y + 7, x + 9, y + 15);
    cv.Brush.Style := bsSolid;
    cv.FillRect(Rect(x + 3, y + 9, x + 7, y + 13));
    cv.FillRect(Rect(x + 11, y + 10, x + 13, y + 15));
    cv.FillRect(Rect(x + 13, y + 6, x + 15, y + 15));
    cv.FillRect(Rect(x + 11, y + 2, x + 13, y + 8));
  end
  else if AId = 'open' then
  begin
    { an open folder }
    cv.Brush.Style := bsClear;
    cv.Rectangle(x + 1, y + 4, x + 15, y + 14);
    cv.Brush.Style := bsSolid;
    cv.FillRect(Rect(x + 1, y + 2, x + 7, y + 5));
    cv.Polygon([Point(x + 3, y + 8), Point(x + 16, y + 8), Point(x + 13, y + 14), Point(x + 1, y + 14)]);
  end
  else if AId = 'new' then
  begin
    { a page with a folded corner }
    cv.Brush.Style := bsClear;
    cv.MoveTo(x + 3, y + 1); cv.LineTo(x + 10, y + 1); cv.LineTo(x + 13, y + 4);
    cv.LineTo(x + 13, y + 15); cv.LineTo(x + 3, y + 15); cv.LineTo(x + 3, y + 1);
    cv.MoveTo(x + 10, y + 1); cv.LineTo(x + 10, y + 4); cv.LineTo(x + 13, y + 4);
    cv.Brush.Style := bsSolid;
  end
  else if AId = 'cut' then
  begin
    { scissors }
    cv.Pen.Width := 2;
    cv.MoveTo(x + 4, y + 11); cv.LineTo(x + 12, y + 2);
    cv.MoveTo(x + 12, y + 11); cv.LineTo(x + 4, y + 2);
    cv.Pen.Width := 1;
    cv.Brush.Style := bsClear;
    cv.Ellipse(x + 2, y + 10, x + 7, y + 15);
    cv.Ellipse(x + 9, y + 10, x + 14, y + 15);
    cv.Brush.Style := bsSolid;
  end
  else if AId = 'paste' then
  begin
    { a clipboard }
    cv.Brush.Style := bsClear;
    cv.Rectangle(x + 2, y + 3, x + 14, y + 15);
    cv.Brush.Style := bsSolid;
    cv.FillRect(Rect(x + 5, y + 1, x + 11, y + 5));
    cv.FillRect(Rect(x + 5, y + 8, x + 11, y + 9));
    cv.FillRect(Rect(x + 5, y + 11, x + 11, y + 12));
  end
  else if AId = 'help' then
  begin
    { a speech bubble with a question mark: ask for help }
    cv.Brush.Style := bsClear;
    cv.RoundRect(x + 1, y + 1, x + 15, y + 12, 7, 7);
    cv.Brush.Style := bsSolid;
    cv.Polygon([Point(x + 3, y + 11), Point(x + 3, y + 15), Point(x + 8, y + 11)]);
    cv.MoveTo(x + 6, y + 4); cv.LineTo(x + 7, y + 3); cv.LineTo(x + 9, y + 3); cv.LineTo(x + 10, y + 4);
    cv.LineTo(x + 10, y + 5); cv.LineTo(x + 8, y + 6); cv.LineTo(x + 8, y + 7);
    cv.FillRect(Rect(x + 7, y + 8, x + 9, y + 9));
  end
  else if AId = 'tostart' then
  begin
    { a bar with a triangle pointing at it: go to the start }
    cv.FillRect(Rect(x + 2, y + 2, x + 4, y + 14));
    cv.Polygon([Point(x + 14, y + 2), Point(x + 14, y + 14), Point(x + 5, y + 8)]);
  end
  else if AId = 'toend' then
  begin
    cv.FillRect(Rect(x + 12, y + 2, x + 14, y + 14));
    cv.Polygon([Point(x + 2, y + 2), Point(x + 2, y + 14), Point(x + 11, y + 8)]);
  end
  else if AId = 'totimeline' then
  begin
    { two timeline lanes with an arrow dropping onto them }
    cv.FillRect(Rect(x + 1, y + 9, x + 15, y + 11));
    cv.FillRect(Rect(x + 1, y + 13, x + 15, y + 15));
    cv.FillRect(Rect(x + 7, y + 1, x + 9, y + 6));
    cv.Polygon([Point(x + 4, y + 5), Point(x + 12, y + 5), Point(x + 8, y + 9)]);
  end
  else if AId = 'up' then
  begin
    { an arrow rising out of a folder: go up one level }
    cv.Polygon([Point(x + 8, y + 1), Point(x + 14, y + 7), Point(x + 10, y + 7), Point(x + 10, y + 10),
      Point(x + 6, y + 10), Point(x + 6, y + 7), Point(x + 2, y + 7)]);
    cv.FillRect(Rect(x + 1, y + 12, x + 15, y + 15));
  end
  else if AId = 'newfolder' then
  begin
    { a folder with a plus }
    cv.FillRect(Rect(x + 1, y + 3, x + 6, y + 5));
    cv.FillRect(Rect(x + 1, y + 5, x + 15, y + 14));
    cv.Brush.Color := TColor($00303030);
    cv.FillRect(Rect(x + 7, y + 7, x + 9, y + 12));
    cv.FillRect(Rect(x + 5, y + 9, x + 11, y + 10));
    cv.Brush.Color := AColor;
  end
  else if AId = 'pause' then
  begin
    cv.FillRect(Rect(x + 3, y + 3, x + 7, y + 13));
    cv.FillRect(Rect(x + 9, y + 3, x + 13, y + 13));
  end
  else if AId = 'mute' then
  begin
    { a loudspeaker; the caller strikes it through while the channel is muted }
    cv.FillRect(Rect(x + 1, y + 6, x + 5, y + 10));
    cv.Polygon([Point(x + 5, y + 6), Point(x + 10, y + 2), Point(x + 10, y + 14), Point(x + 5, y + 10)]);
    cv.MoveTo(x + 12, y + 5); cv.LineTo(x + 14, y + 8); cv.LineTo(x + 12, y + 11);
  end
  else if AId = 'fx' then
  begin
    { one cycle of a wave: an effect on the channel }
    cv.Pen.Width := 2;
    cv.MoveTo(x + 1, y + 8);
    cv.LineTo(x + 4, y + 3); cv.LineTo(x + 8, y + 13); cv.LineTo(x + 12, y + 3); cv.LineTo(x + 15, y + 8);
    cv.Pen.Width := 1;
  end
  else if AId = 'loop' then
  begin
    cv.Brush.Style := bsClear;
    cv.Rectangle(x + 1, y + 3, x + 15, y + 13);
    cv.Brush.Style := bsSolid;
    cv.Polygon([Point(x + 9, y + 1), Point(x + 9, y + 6), Point(x + 13, y + 3)]);
  end
  else if AId = 'add' then
  begin
    cv.FillRect(Rect(x + 7, y + 2, x + 9, y + 14));
    cv.FillRect(Rect(x + 2, y + 7, x + 14, y + 9));
  end
  else if AId = 'select' then
    cv.Polygon([Point(x + 3, y + 1), Point(x + 3, y + 13), Point(x + 6, y + 10), Point(x + 9, y + 15),
      Point(x + 11, y + 14), Point(x + 8, y + 9), Point(x + 12, y + 9)])
  else if AId = 'range' then
  begin
    cv.Brush.Style := bsClear;
    cv.Pen.Style := psDash;
    cv.Rectangle(x + 1, y + 3, x + 15, y + 13);
    cv.Pen.Style := psSolid;
    cv.Brush.Style := bsSolid;
  end
  else if AId = 'split' then
  begin
    cv.FillRect(Rect(x + 7, y + 1, x + 9, y + 15));
    cv.Polygon([Point(x + 2, y + 5), Point(x + 6, y + 8), Point(x + 2, y + 11)]);
    cv.Polygon([Point(x + 14, y + 5), Point(x + 10, y + 8), Point(x + 14, y + 11)]);
  end
  else if AId = 'erase' then
  begin
    cv.Pen.Width := 2;
    cv.MoveTo(x + 3, y + 3); cv.LineTo(x + 13, y + 13);
    cv.MoveTo(x + 13, y + 3); cv.LineTo(x + 3, y + 13);
    cv.Pen.Width := 1;
  end
  else if AId = 'export' then
  begin
    { an arrow leaving a tray }
    cv.FillRect(Rect(x + 1, y + 11, x + 3, y + 15));
    cv.FillRect(Rect(x + 13, y + 11, x + 15, y + 15));
    cv.FillRect(Rect(x + 1, y + 13, x + 15, y + 15));
    cv.FillRect(Rect(x + 7, y + 4, x + 9, y + 11));
    cv.Polygon([Point(x + 3, y + 6), Point(x + 8, y + 1), Point(x + 13, y + 6)]);
  end
  else if AId = 'wavedit' then
  begin
    { waveform bars: open the sound in the WAV editor }
    cv.FillRect(Rect(x + 1, y + 6, x + 3, y + 10));
    cv.FillRect(Rect(x + 4, y + 3, x + 6, y + 13));
    cv.FillRect(Rect(x + 7, y + 1, x + 9, y + 15));
    cv.FillRect(Rect(x + 10, y + 4, x + 12, y + 12));
    cv.FillRect(Rect(x + 13, y + 6, x + 15, y + 10));
  end
  else if AId = 'tools' then
  begin
    for k := 0 to 2 do
    begin
      cv.FillRect(Rect(x + 1, y + 3 + k * 5, x + 15, y + 4 + k * 5));
      cv.FillRect(Rect(x + 3 + ((k * 5) mod 9), y + 1 + k * 5, x + 6 + ((k * 5) mod 9), y + 6 + k * 5));
    end;
  end
  else if (AId = 'undo') or (AId = 'redo') then
  begin
    cv.Pen.Width := 2;
    if AId = 'undo' then
    begin
      cv.MoveTo(x + 3, y + 7); cv.LineTo(x + 10, y + 7);
      cv.LineTo(x + 13, y + 9); cv.LineTo(x + 13, y + 12);
      cv.Pen.Width := 1;
      cv.Polygon([Point(x + 1, y + 7), Point(x + 6, y + 3), Point(x + 6, y + 11)]);
    end
    else
    begin
      cv.MoveTo(x + 13, y + 7); cv.LineTo(x + 6, y + 7);
      cv.LineTo(x + 3, y + 9); cv.LineTo(x + 3, y + 12);
      cv.Pen.Width := 1;
      cv.Polygon([Point(x + 15, y + 7), Point(x + 10, y + 3), Point(x + 10, y + 11)]);
    end;
  end
  else if (AId = 'zoomin') or (AId = 'zoomout') then
  begin
    cv.Brush.Style := bsClear;
    cv.Ellipse(x + 1, y + 1, x + 11, y + 11);
    cv.Brush.Style := bsSolid;
    cv.Pen.Width := 2;
    cv.MoveTo(x + 10, y + 10); cv.LineTo(x + 14, y + 14);
    cv.Pen.Width := 1;
    cv.FillRect(Rect(x + 3, y + 5, x + 9, y + 7));
    if AId = 'zoomin' then cv.FillRect(Rect(x + 5, y + 3, x + 7, y + 9));
  end
  else if (AId = 'left') or (AId = 'right') then
  begin
    if AId = 'left' then
      cv.Polygon([Point(x + 11, y + 2), Point(x + 11, y + 14), Point(x + 4, y + 8)])
    else
      cv.Polygon([Point(x + 5, y + 2), Point(x + 5, y + 14), Point(x + 12, y + 8)]);
  end
  else if AId = 'minus' then
    cv.FillRect(Rect(x + 2, y + 7, x + 14, y + 9))
  else if AId = 'clone' then
  begin
    cv.Brush.Style := bsClear;
    cv.Rectangle(x + 1, y + 1, x + 10, y + 10);
    cv.Rectangle(x + 6, y + 6, x + 15, y + 15);
    cv.Brush.Style := bsSolid;
  end
  else if AId = 'deletecache' then
  begin
    { a stack of discs (the cache) struck through with a cross: delete what is no longer used }
    cv.Brush.Style := bsClear;
    cv.Ellipse(x + 1, y + 1, x + 13, y + 6);
    cv.Ellipse(x + 1, y + 5, x + 13, y + 10);
    cv.Ellipse(x + 1, y + 9, x + 13, y + 14);
    cv.Brush.Style := bsSolid;
    cv.Pen.Width := 2;
    cv.MoveTo(x + 9, y + 9); cv.LineTo(x + 15, y + 15);
    cv.MoveTo(x + 15, y + 9); cv.LineTo(x + 9, y + 15);
    cv.Pen.Width := 1;
  end
  else if AId = 'trash' then
  begin
    cv.FillRect(Rect(x + 2, y + 3, x + 14, y + 5));
    cv.FillRect(Rect(x + 6, y + 1, x + 10, y + 3));
    cv.Brush.Style := bsClear;
    cv.Rectangle(x + 3, y + 5, x + 13, y + 15);
    cv.Brush.Style := bsSolid;
    cv.MoveTo(x + 6, y + 7); cv.LineTo(x + 6, y + 13);
    cv.MoveTo(x + 9, y + 7); cv.LineTo(x + 9, y + 13);
  end
  else if (AId = 'save') or (AId = 'saveas') then
  begin
    { a floppy disk; "save as" is smaller, with a plus at the corner }
    cv.Brush.Style := bsClear;
    if AId = 'save' then cv.Rectangle(x + 1, y + 1, x + 15, y + 15)
    else cv.Rectangle(x, y, x + 13, y + 13);
    cv.Brush.Style := bsSolid;
    if AId = 'save' then
    begin
      cv.FillRect(Rect(x + 4, y + 1, x + 12, y + 6));
      cv.FillRect(Rect(x + 4, y + 9, x + 12, y + 15));
    end
    else
    begin
      cv.FillRect(Rect(x + 3, y, x + 10, y + 4));
      cv.FillRect(Rect(x + 3, y + 8, x + 10, y + 13));
      cv.FillRect(Rect(x + 11, y + 8, x + 13, y + 16));
      cv.FillRect(Rect(x + 8, y + 11, x + 16, y + 13));
    end;
  end
  else if AId = 'load' then
  begin
    cv.FillRect(Rect(x + 1, y + 3, x + 7, y + 5));
    cv.Brush.Style := bsClear;
    cv.Rectangle(x + 1, y + 5, x + 15, y + 14);
    cv.Brush.Style := bsSolid;
  end
  else if AId = 'place' then
  begin
    cv.FillRect(Rect(x + 7, y + 1, x + 9, y + 9));
    cv.Polygon([Point(x + 3, y + 8), Point(x + 8, y + 13), Point(x + 13, y + 8)]);
    cv.FillRect(Rect(x + 2, y + 14, x + 14, y + 15));
  end
  else if AId = 'fill' then
  begin
    for k := 0 to 3 do cv.FillRect(Rect(x + 1 + k * 4, y + 4, x + 3 + k * 4, y + 12));
  end
  else if AId = 'euclid' then
  begin
    cv.Brush.Style := bsClear;
    cv.Ellipse(x + 1, y + 1, x + 15, y + 15);
    cv.Brush.Style := bsSolid;
    cv.FillRect(Rect(x + 6, y, x + 10, y + 4));
    cv.FillRect(Rect(x + 11, y + 9, x + 15, y + 13));
    cv.FillRect(Rect(x + 1, y + 9, x + 5, y + 13));
  end
  else if AId = 'random' then
  begin
    cv.Brush.Style := bsClear;
    cv.Rectangle(x + 1, y + 1, x + 15, y + 15);
    cv.Brush.Style := bsSolid;
    cv.FillRect(Rect(x + 4, y + 4, x + 6, y + 6));
    cv.FillRect(Rect(x + 10, y + 4, x + 12, y + 6));
    cv.FillRect(Rect(x + 7, y + 7, x + 9, y + 9));
    cv.FillRect(Rect(x + 4, y + 10, x + 6, y + 12));
    cv.FillRect(Rect(x + 10, y + 10, x + 12, y + 12));
  end
  else if AId = 'clear' then
  begin
    cv.Brush.Style := bsClear;
    cv.Rectangle(x + 1, y + 3, x + 15, y + 13);
    cv.Brush.Style := bsSolid;
    cv.Pen.Width := 2;
    cv.MoveTo(x + 3, y + 12); cv.LineTo(x + 13, y + 4);
    cv.Pen.Width := 1;
  end
  else if (AId = 'addrow') or (AId = 'delrow') then
  begin
    cv.Brush.Style := bsClear;
    cv.Rectangle(x + 1, y + 2, x + 15, y + 8);
    cv.Brush.Style := bsSolid;
    cv.FillRect(Rect(x + 4, y + 11, x + 12, y + 13));
    if AId = 'addrow' then cv.FillRect(Rect(x + 7, y + 9, x + 9, y + 15));
  end
  else if AId = 'ai' then
    cv.Polygon([Point(x + 8, y + 1), Point(x + 10, y + 6), Point(x + 15, y + 8), Point(x + 10, y + 10),
      Point(x + 8, y + 15), Point(x + 6, y + 10), Point(x + 1, y + 8), Point(x + 6, y + 6)])
  else if AId = 'scene' then
  begin
    cv.Brush.Style := bsClear;
    cv.Rectangle(x + 1, y + 2, x + 15, y + 14);
    cv.Brush.Style := bsSolid;
    cv.Polygon([Point(x + 6, y + 5), Point(x + 6, y + 11), Point(x + 11, y + 8)]);
  end
  else if AId = 'selall' then
  begin
    cv.Brush.Style := bsClear;
    cv.Pen.Style := psDash;
    cv.Rectangle(x + 1, y + 2, x + 15, y + 14);
    cv.Pen.Style := psSolid;
    cv.Brush.Style := bsSolid;
    cv.FillRect(Rect(x + 4, y + 5, x + 12, y + 11));
  end
  else if AId = 'zoomsel' then
  begin
    { a magnifier with a marked stretch inside it }
    cv.Brush.Style := bsClear;
    cv.Ellipse(x + 1, y + 1, x + 11, y + 11);
    cv.Brush.Style := bsSolid;
    cv.Pen.Width := 2;
    cv.MoveTo(x + 10, y + 10); cv.LineTo(x + 14, y + 14);
    cv.Pen.Width := 1;
    cv.FillRect(Rect(x + 3, y + 3, x + 4, y + 9));
    cv.FillRect(Rect(x + 8, y + 3, x + 9, y + 9));
    cv.FillRect(Rect(x + 4, y + 5, x + 8, y + 7));
  end
  else if AId = 'fit' then
  begin
    cv.FillRect(Rect(x, y + 2, x + 2, y + 14));
    cv.FillRect(Rect(x + 14, y + 2, x + 16, y + 14));
    cv.Polygon([Point(x + 8, y + 4), Point(x + 8, y + 12), Point(x + 3, y + 8)]);
    cv.Polygon([Point(x + 8, y + 4), Point(x + 8, y + 12), Point(x + 13, y + 8)]);
  end
  else if AId = 'trim' then
  begin
    cv.FillRect(Rect(x + 1, y + 2, x + 3, y + 14));
    cv.FillRect(Rect(x + 1, y + 2, x + 5, y + 4));
    cv.FillRect(Rect(x + 1, y + 12, x + 5, y + 14));
    cv.FillRect(Rect(x + 13, y + 2, x + 15, y + 14));
    cv.FillRect(Rect(x + 11, y + 2, x + 15, y + 4));
    cv.FillRect(Rect(x + 11, y + 12, x + 15, y + 14));
    cv.FillRect(Rect(x + 6, y + 6, x + 7, y + 10));
    cv.FillRect(Rect(x + 8, y + 4, x + 9, y + 12));
    cv.FillRect(Rect(x + 10, y + 6, x + 11, y + 10));
  end
  else if AId = 'cut' then
  begin
    { scissors }
    cv.Pen.Width := 2;
    cv.MoveTo(x + 4, y + 1); cv.LineTo(x + 10, y + 10);
    cv.MoveTo(x + 12, y + 1); cv.LineTo(x + 6, y + 10);
    cv.Pen.Width := 1;
    cv.Brush.Style := bsClear;
    cv.Ellipse(x + 1, y + 10, x + 7, y + 16);
    cv.Ellipse(x + 9, y + 10, x + 15, y + 16);
    cv.Brush.Style := bsSolid;
  end
  else if AId = 'silence' then
  begin
    { a loudspeaker crossed out }
    cv.Polygon([Point(x + 1, y + 6), Point(x + 4, y + 6), Point(x + 8, y + 2), Point(x + 8, y + 14),
      Point(x + 4, y + 10), Point(x + 1, y + 10)]);
    cv.Pen.Width := 2;
    cv.MoveTo(x + 10, y + 5); cv.LineTo(x + 15, y + 11);
    cv.MoveTo(x + 15, y + 5); cv.LineTo(x + 10, y + 11);
    cv.Pen.Width := 1;
  end
  else if AId = 'reverse' then
  begin
    cv.Polygon([Point(x + 8, y + 3), Point(x + 8, y + 13), Point(x + 1, y + 8)]);
    cv.Polygon([Point(x + 15, y + 3), Point(x + 15, y + 13), Point(x + 8, y + 8)]);
  end
  else if AId = 'normalize' then
  begin
    cv.FillRect(Rect(x + 1, y + 1, x + 15, y + 3));
    cv.Polygon([Point(x + 3, y + 9), Point(x + 8, y + 4), Point(x + 13, y + 9)]);
    cv.FillRect(Rect(x + 7, y + 8, x + 9, y + 15));
  end
  else if AId = 'fadein' then
    cv.Polygon([Point(x + 1, y + 13), Point(x + 15, y + 13), Point(x + 15, y + 2)])
  else if AId = 'fadeout' then
    cv.Polygon([Point(x + 1, y + 2), Point(x + 1, y + 13), Point(x + 15, y + 13)])
  else if AId = 'gain' then
  begin
    { a loudspeaker with sound waves }
    cv.Polygon([Point(x + 1, y + 6), Point(x + 4, y + 6), Point(x + 8, y + 2), Point(x + 8, y + 14),
      Point(x + 4, y + 10), Point(x + 1, y + 10)]);
    cv.MoveTo(x + 10, y + 5); cv.LineTo(x + 12, y + 8); cv.LineTo(x + 10, y + 11);
    cv.MoveTo(x + 12, y + 3); cv.LineTo(x + 15, y + 8); cv.LineTo(x + 12, y + 13);
  end
  else if AId = 'extend' then
  begin
    { audio, then a stretch of silence after it }
    cv.FillRect(Rect(x + 1, y + 3, x + 3, y + 13));
    cv.Brush.Style := bsClear;
    cv.Pen.Style := psDash;
    cv.Rectangle(x + 5, y + 4, x + 15, y + 12);
    cv.Pen.Style := psSolid;
    cv.Brush.Style := bsSolid;
  end
  else if AId = 'stretch' then
  begin
    cv.FillRect(Rect(x + 4, y + 7, x + 12, y + 9));
    cv.Polygon([Point(x + 5, y + 3), Point(x + 5, y + 13), Point(x + 1, y + 8)]);
    cv.Polygon([Point(x + 11, y + 3), Point(x + 11, y + 13), Point(x + 15, y + 8)]);
  end
  else if AId = 'lock' then
  begin
    { a padlock: an arched shackle over a solid body }
    cv.Brush.Style := bsClear;
    cv.Pen.Width := 2;
    cv.RoundRect(x + 4, y + 1, x + 12, y + 10, 6, 6);
    cv.Pen.Width := 1;
    cv.Brush.Style := bsSolid;
    cv.FillRect(Rect(x + 2, y + 7, x + 14, y + 15));
  end
  else if AId = 'close' then
  begin
    { a ring with a cross: dismiss / close }
    cv.Brush.Style := bsClear;
    cv.Pen.Width := 2;
    cv.Ellipse(x, y, x + 16, y + 16);
    cv.MoveTo(x + 5, y + 5); cv.LineTo(x + 11, y + 11);
    cv.MoveTo(x + 11, y + 5); cv.LineTo(x + 5, y + 11);
    cv.Pen.Width := 1;
  end
  else if AId = 'ok' then
  begin
    cv.Pen.Width := 2;
    cv.MoveTo(x + 2, y + 8); cv.LineTo(x + 6, y + 12); cv.LineTo(x + 14, y + 3);
    cv.Pen.Width := 1;
  end
  else
  begin
    cv.Brush.Style := bsClear;
    cv.Rectangle(x + 2, y + 2, x + 14, y + 14);
  end;
  cv.Brush.Style := bsSolid;
end;

procedure TGLIconBar.SetLit(AValue: Integer);
begin
  if FLit = AValue then Exit;
  FLit := AValue;
  Invalidate;
end;

function TGLIconBar.IsLit(AIndex: Integer): Boolean;
begin
  Result := (AIndex = FActive) or (((FLit shr AIndex) and 1) = 1);
end;

procedure TGLIconBar.PaintGL;
var
  cv: TGLCanvas;
  i: Integer;
  r: TRect;
  face, back, ink, accent: TColor;
  dis: Boolean;
begin
  cv := GL;
  face := Sys(clBtnFace);
  { the bar always takes the colour of a container that paints its own body (a recessed panel, a
    title bar, a form with its own background); it stays the face colour when nothing does }
  if not GLParentBackdrop(Self, back) then back := face;
  face := back;
  ink := Sys(clBtnText);
  accent := Sys(clHighlight);
  cv.Brush.Style := bsSolid;
  cv.Brush.Color := face;
  cv.Pen.Style := psClear;
  cv.FillRect(Rect(0, 0, Width, Height));
  for i := 0 to FIds.Count - 1 do
  begin
    r := CellRect(i);
    dis := (i < Length(FDisabled)) and FDisabled[i];
    { a transparent bar never fills a cell: hover / press show on the icon itself (below) }
    if FTransparent then cv.Brush.Color := face
    else if (i = FPressed) and not dis then cv.Brush.Color := Blend(face, accent, 0.45)
    else if IsLit(i) then cv.Brush.Color := Blend(face, accent, 0.28)
    else if (i = FHover) and not dis then cv.Brush.Color := Blend(face, ink, 0.12)
    else cv.Brush.Color := face;
    cv.Pen.Style := psClear;
    cv.RoundRect(r.Left, r.Top, r.Right, r.Bottom, 6, 6);
    if IsLit(i) then
    begin
      cv.Brush.Color := accent;
      cv.FillRect(Rect(r.Left + 4, r.Bottom - 3, r.Right - 4, r.Bottom - 1));
    end;
    if dis then DrawIcon(cv, FIds[i], r, Blend(face, ink, 0.35))
    else if FTransparent and ((i = FPressed) or (i = FHover) or IsLit(i)) then DrawIcon(cv, FIds[i], r, accent)   // lights up like the collapse arrow
    else DrawIcon(cv, FIds[i], r, ink);
  end;
end;

end.
