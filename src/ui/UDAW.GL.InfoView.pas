unit UDAW.GL.InfoView;

{ TGLInfoView - UDAW's OpenGL 3.3 viewer for a structured report (see UDAW.SystemInfo): section
  headers, then rows of "key  value", drawn with TGLCanvas like every other GL widget and placed on
  the form at design time.

    * mouse wheel / thumb / keys scroll it; a click selects a row
    * Filter shows only the rows whose key or value contains the text (sections with no match are hidden)
    * Ctrl+C copies the selected row, or the whole report when none is selected; CopyAll / CopyRow
      do the same from code
    * a value too long for its column shows in full as the hint under the pointer }

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Types, System.UITypes,
  System.Math, System.StrUtils, Vcl.Controls, Vcl.Graphics, Vcl.Forms, Vcl.Themes, Vcl.Clipbrd,
  UDAW.GL.Canvas, UDAW.GL.Widgets, UDAW.SystemInfo;

type
  TGLInfoView = class(TGLWidget)
  private
    FInfo: TSysInfo;
    FShown: TArray<Integer>;      // indices into FInfo of the rows that pass the filter
    FFilter: string;
    FTop: Integer;                // first display row drawn
    FSel: Integer;                // selected display row, -1 none
    FDragging: Boolean;
    FGrab: Integer;
    FKeyW: Integer;
    function RowH: Integer;
    function VisibleRows: Integer;
    function MaxTop: Integer;
    function NeedBar: Boolean;
    function ThumbRect: TRect;
    function ColumnX: Integer;
    procedure SetTop(AValue: Integer);
    procedure SetFilter(const AValue: string);
    procedure Rebuild;
    procedure SelectRow(ARow: Integer);
    function RowAt(Y: Integer): Integer;
    procedure UpdateHoverHint(X, Y: Integer);
    procedure WMGetDlgCode(var Msg: TWMGetDlgCode); message WM_GETDLGCODE;
  protected
    procedure PaintGL; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { replaces what is shown with a copy of AInfo, keeping the scroll position where it can }
    procedure SetReport(AInfo: TSysInfo);
    procedure Clear;
    { the whole report as text }
    function ReportText: string;
    procedure CopyAll;
    procedure CopyRow;
    { number of rows (not sections) the filter lets through }
    function MatchCount: Integer;
    property Filter: string read FFilter write SetFilter;
  published
    property TabStop default True;
    property Font;
    property ParentFont;
  end;

implementation

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

constructor TGLInfoView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  FInfo := TSysInfo.Create;
  FSel := -1;
  FKeyW := 300;
  Width := 400;
  Height := 300;
end;

destructor TGLInfoView.Destroy;
begin
  FInfo.Free;
  inherited Destroy;
end;

procedure TGLInfoView.WMGetDlgCode(var Msg: TWMGetDlgCode);
begin
  Msg.Result := DLGC_WANTARROWS or DLGC_WANTCHARS;
end;

function TGLInfoView.RowH: Integer;
begin
  Result := Max(18, Abs(Font.Height) + 8);
end;

function TGLInfoView.VisibleRows: Integer;
begin
  Result := Max(1, Height div RowH);
end;

function TGLInfoView.MaxTop: Integer;
begin
  Result := Max(0, Length(FShown) - VisibleRows);
end;

function TGLInfoView.NeedBar: Boolean;
begin
  Result := Length(FShown) > VisibleRows;
end;

function TGLInfoView.ThumbRect: TRect;
var
  th, ty: Integer;
begin
  th := Max(24, Round(Height * VisibleRows / Max(1, Length(FShown))));
  if MaxTop > 0 then ty := Round((Height - th) * FTop / MaxTop) else ty := 0;
  Result := Rect(Width - 10, ty, Width - 2, ty + th);
end;

{ the column the values start in: a share of the width, never so narrow that keys are cut short }
function TGLInfoView.ColumnX: Integer;
begin
  Result := EnsureRange(Width * 38 div 100, 160, 420);
end;

procedure TGLInfoView.SetTop(AValue: Integer);
begin
  AValue := EnsureRange(AValue, 0, MaxTop);
  if AValue = FTop then Exit;
  FTop := AValue;
  Invalidate;
end;

procedure TGLInfoView.Resize;
begin
  inherited Resize;
  FTop := EnsureRange(FTop, 0, MaxTop);
end;

{ the rows to show: those that match the filter, each section kept only when one of its rows is }
procedure TGLInfoView.Rebuild;
var
  i, pending: Integer;
  f: string;
  it: TSysInfoItem;
begin
  f := LowerCase(Trim(FFilter));
  FShown := nil;
  pending := -1;
  for i := 0 to FInfo.Count - 1 do
  begin
    it := FInfo[i];
    if it.Kind = sikSection then
      pending := i
    else if (f = '') or (Pos(f, LowerCase(it.Key)) > 0) or (Pos(f, LowerCase(it.Value)) > 0) then
    begin
      if pending >= 0 then
      begin
        FShown := FShown + [pending];
        pending := -1;
      end;
      FShown := FShown + [i];
    end;
  end;
  FTop := EnsureRange(FTop, 0, MaxTop);
  FSel := -1;
  Invalidate;
end;

procedure TGLInfoView.SetFilter(const AValue: string);
begin
  if FFilter = AValue then Exit;
  FFilter := AValue;
  FTop := 0;
  Rebuild;
end;

procedure TGLInfoView.SetReport(AInfo: TSysInfo);
var
  i, keepTop: Integer;
begin
  keepTop := FTop;
  FInfo.Clear;
  for i := 0 to AInfo.Count - 1 do
    if AInfo[i].Kind = sikSection then FInfo.Section(AInfo[i].Key)
    else FInfo.Row(AInfo[i].Key, AInfo[i].Value);
  Rebuild;
  FTop := EnsureRange(keepTop, 0, MaxTop);
end;

procedure TGLInfoView.Clear;
begin
  FInfo.Clear;
  Rebuild;
end;

function TGLInfoView.ReportText: string;
begin
  Result := FInfo.AsText;
end;

function TGLInfoView.MatchCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FShown) do
    if FInfo[FShown[i]].Kind = sikRow then Inc(Result);
end;

procedure TGLInfoView.CopyAll;
begin
  Clipboard.AsText := FInfo.AsText;
end;

procedure TGLInfoView.CopyRow;
var
  it: TSysInfoItem;
begin
  if (FSel < 0) or (FSel > High(FShown)) then
  begin
    CopyAll;
    Exit;
  end;
  it := FInfo[FShown[FSel]];
  if it.Kind = sikSection then Clipboard.AsText := it.Key
  else Clipboard.AsText := it.Key + ' : ' + it.Value;
end;

procedure TGLInfoView.SelectRow(ARow: Integer);
begin
  if Length(FShown) = 0 then Exit;
  ARow := EnsureRange(ARow, 0, High(FShown));
  FSel := ARow;
  if FSel < FTop then FTop := FSel
  else if FSel >= FTop + VisibleRows then FTop := FSel - VisibleRows + 1;
  FTop := EnsureRange(FTop, 0, MaxTop);
  Invalidate;
end;

function TGLInfoView.RowAt(Y: Integer): Integer;
begin
  Result := FTop + Y div RowH;
  if (Result < 0) or (Result > High(FShown)) then Result := -1;
end;

procedure TGLInfoView.UpdateHoverHint(X, Y: Integer);
var
  r: Integer;
  txt: string;
  it: TSysInfoItem;
begin
  txt := '';
  r := RowAt(Y);
  if (r >= 0) and (X < Width - 12) then
  begin
    it := FInfo[FShown[r]];
    if (it.Kind = sikRow) and (Length(it.Value) > 0) then txt := it.Key + ': ' + it.Value;
  end;
  if txt <> Hint then
  begin
    Hint := txt;
    Application.CancelHint;
  end;
end;

procedure TGLInfoView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  tr: TRect;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;
  if CanFocus then SetFocus;
  if NeedBar and (X >= Width - 12) then
  begin
    tr := ThumbRect;
    if (Y >= tr.Top) and (Y < tr.Bottom) then
    begin
      FDragging := True;
      FGrab := Y - tr.Top;
    end
    else if Y < tr.Top then SetTop(FTop - VisibleRows)
    else SetTop(FTop + VisibleRows);
    Exit;
  end;
  SelectRow(RowAt(Y));
end;

procedure TGLInfoView.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  room: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if FDragging then
  begin
    room := Height - (ThumbRect.Bottom - ThumbRect.Top);
    if room > 0 then SetTop(Round(MaxTop * EnsureRange((Y - FGrab) / room, 0, 1)));
    Exit;
  end;
  UpdateHoverHint(X, Y);
end;

procedure TGLInfoView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FDragging := False;
end;

function TGLInfoView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := True;
  SetTop(FTop - Sign(WheelDelta) * 3);
end;

procedure TGLInfoView.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if (ssCtrl in Shift) and ((Key = Ord('C')) or (Key = VK_INSERT)) then
  begin
    CopyRow;
    Key := 0;
    Exit;
  end;
  case Key of
    VK_UP: SelectRow(Max(0, FSel) - IfThen(FSel < 0, 0, 1));
    VK_DOWN: SelectRow(FSel + 1);
    VK_PRIOR: SelectRow(Max(0, FSel) - VisibleRows);
    VK_NEXT: SelectRow(Max(0, FSel) + VisibleRows);
    VK_HOME: SelectRow(0);
    VK_END: SelectRow(High(FShown));
  else
    Exit;
  end;
  Key := 0;
end;

procedure TGLInfoView.PaintGL;
var
  cv: TGLCanvas;
  face, field, ink, accent, dim, band: TColor;
  y, h, th, barW, colX, r: Integer;
  it: TSysInfoItem;
  tr: TRect;
begin
  cv := GL;
  face := FaceColor;
  field := FieldColor;
  ink := Sys(clWindowText);
  accent := AccentColor;
  dim := Blend(field, ink, 0.62);
  band := Blend(field, accent, 0.32);
  h := RowH;
  if NeedBar then barW := 12 else barW := 0;
  colX := ColumnX;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := field;
  cv.FillRect(Rect(0, 0, Width, Height));
  th := cv.TextHeight('Ag');
  y := 0;
  r := FTop;
  while (r <= High(FShown)) and (y < Height) do
  begin
    it := FInfo[FShown[r]];
    if it.Kind = sikSection then
    begin
      cv.Brush.Color := band;
      cv.FillRect(Rect(0, y, Width - barW, y + h));
      cv.Brush.Color := accent;
      cv.FillRect(Rect(0, y, 3, y + h));
      cv.Font.Style := [fsBold];
      cv.Font.Color := ink;
      cv.TextOut(10, y + (h - th) div 2, it.Key);
      cv.Font.Style := [];
    end
    else
    begin
      if r = FSel then
      begin
        cv.Brush.Color := accent;
        cv.FillRect(Rect(0, y, Width - barW, y + h));
        cv.Font.Color := Sys(clHighlightText);
        cv.PushClip(Rect(0, y, colX - 8, y + h));
        cv.TextOut(10, y + (h - th) div 2, it.Key);
        cv.PopClip;
        cv.PushClip(Rect(colX, y, Width - barW, y + h));
        cv.TextOut(colX, y + (h - th) div 2, it.Value);
        cv.PopClip;
      end
      else
      begin
        if (r and 1) = 1 then
        begin
          cv.Brush.Color := Blend(field, ink, 0.045);
          cv.FillRect(Rect(0, y, Width - barW, y + h));
        end;
        cv.Font.Color := dim;
        cv.PushClip(Rect(0, y, colX - 8, y + h));
        cv.TextOut(10, y + (h - th) div 2, it.Key);
        cv.PopClip;
        cv.Font.Color := ink;
        cv.PushClip(Rect(colX, y, Width - barW, y + h));
        cv.TextOut(colX, y + (h - th) div 2, it.Value);
        cv.PopClip;
      end;
    end;
    Inc(y, h);
    Inc(r);
  end;
  if Length(FShown) = 0 then
  begin
    cv.Font.Color := dim;
    cv.TextOut(10, 8, IfThen(FFilter <> '', 'Nothing matches "' + FFilter + '"', 'No information yet'));
  end;
  if NeedBar then
  begin
    tr := ThumbRect;
    cv.Brush.Color := Blend(field, ink, 0.12);
    cv.FillRect(Rect(Width - 12, 0, Width, Height));
    GLDrawScrollThumb(cv, Self, 0, tr, True, FDragging, Hover, field, InkColor, AccentColor);
  end;
  cv.Pen.Style := psSolid;
  if Focused then cv.Pen.Color := AccentColor else cv.Pen.Color := Blend(face, InkColor, 0.25);
  cv.Brush.Style := bsClear;
  cv.Rectangle(0, 0, Width, Height);
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
end;

initialization
  RegisterClass(TGLInfoView);

end.
