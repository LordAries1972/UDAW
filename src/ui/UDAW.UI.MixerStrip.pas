unit UDAW.UI.MixerStrip;

{ The Mixer's channel strip, built from UDAW's own OpenGL 3.3 widget set
  (UDAW.GL.Widgets): TGLCombo for the In / Out choosers, TGLButton for
  M / S / R, + FX and + Send, TGLSlider for the fader and the pan, TGLLabel for
  the readouts, plus a GL level meter. Nothing here is hit-tested by hand - every
  control is a real widget with its own hover / pressed / focus / hint behaviour.

  One TGLMixerStrip is one mixer strip. The Mixer tab keeps them in step with the
  project's TMixerModel: Configure (structure - names, routing, the effect list)
  and UpdateLive (fader, pan, flags, meters) are fed from the model and the strip
  reports user edits back through its events; it never touches the model itself. }

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Types,
  System.UITypes, System.Math, System.Generics.Collections, Vcl.Controls,
  System.StrUtils, Vcl.Graphics, Vcl.Menus, Vcl.StdCtrls, UDAW.GL.Canvas, UDAW.GL.Widgets,
  UDAW.GL.Menus, UDAW.UI.ThemeColors;

const
  MIX_DB_MIN = -60.0;
  MIX_DB_MAX = 6.0;

type
  TGLMixerStrip = class;

  TMixRowKind = (rkEffect, rkAddFx, rkSend, rkAddSend, rkMore);

  TMixInsertInfo = record
    Name: string;
    Bypass: Boolean;
  end;

  { structure of one strip: changes rarely, so it is applied from a posted sync }
  TMixStripInfo = record
    Id: Integer;
    Name, Sub: string;
    Tint: TColor;
    Selected, IsMaster, ShowIn, ShowOut, ShowSolo, CanArm: Boolean;
    InTexts: TArray<string>;
    InIds: TArray<Integer>;
    InSel: Integer;
    OutTexts: TArray<string>;
    OutIds: TArray<Integer>;
    OutSel: Integer;
    Inserts: TArray<TMixInsertInfo>;
    Sends: TArray<string>;
  end;

  { the values that move: applied on every refresh }
  TMixStripLive = record
    FaderDb, Pan: Double;
    Muted, Soloed, Armed: Boolean;
    PeakL, PeakR, HoldL, HoldR: Double;
    Clip: Boolean;
  end;

  TMixStripEvent = procedure(Sender: TGLMixerStrip) of object;
  TMixStripValueEvent = procedure(Sender: TGLMixerStrip; AValue: Double) of object;
  TMixStripIdEvent = procedure(Sender: TGLMixerStrip; AId: Integer) of object;
  TMixStripIndexEvent = procedure(Sender: TGLMixerStrip; AIndex: Integer) of object;
  TMixStripFlagEvent = procedure(Sender: TGLMixerStrip; AFlag: Integer; AValue: Boolean) of object;
  TMixStripPointEvent = procedure(Sender: TGLMixerStrip; const AScreenPt: TPoint) of object;

  { a row of the effect / send list, or one of the + buttons under it }
  TMixRow = class(TGLButton)
  private
    FKind: TMixRowKind;
    FIndex: Integer;
    FBypass: Boolean;
    FTint: TColor;
  protected
    procedure PaintGL; override;
  public
    constructor Create(AOwner: TComponent); override;
    property Kind: TMixRowKind read FKind write FKind;
    property Index: Integer read FIndex write FIndex;
    property Bypass: Boolean read FBypass write FBypass;
    property Tint: TColor read FTint write FTint;
  end;

  { a boxed value readout (fader dB, peak) in the strip's own colours }
  TMixReadout = class(TGLWidget)
  protected
    procedure PaintGL; override;
  public
    constructor Create(AOwner: TComponent); override;
  end;

  { the In / Out chooser: a TGLCombo (drop-down, wheel, keyboard) painted in the
    strip's colours }
  TMixCombo = class(TGLCombo)
  protected
    procedure PaintGL; override;
  end;

  { Mute / Solo / Record: a drawn icon button that lights in its own colour while down }
  TMixGlyph = (mgText, mgMute, mgSolo, mgRecord);

  TMixToggle = class(TGLButton)
  private
    FLit: TColor;
    FGlyph: TMixGlyph;
  protected
    procedure PaintGL; override;
  public
    constructor Create(AOwner: TComponent); override;
    property LitColor: TColor read FLit write FLit;
    property Glyph: TMixGlyph read FGlyph write FGlyph;
  end;

  { the vertical fader: groove, 6 dB ticks, a unity mark and a wide cap }
  TMixFader = class(TGLSlider)
  protected
    procedure PaintGL; override;
  public
    constructor Create(AOwner: TComponent); override;
  end;

  { the pan control: a centre-notched groove and a small thumb }
  TMixPan = class(TGLSlider)
  private
    FTint: TColor;
    procedure SetTint(AValue: TColor);
  protected
    procedure PaintGL; override;
  public
    constructor Create(AOwner: TComponent); override;
    property Tint: TColor read FTint write SetTint;
  end;

  { dB scale + the L/R peak bars with hold caps, and the latching clip cap on top
    (click it to reset) }
  TMixMeter = class(TGLWidget)
  private
    FPeakL, FPeakR, FHoldL, FHoldR: Double;
    FClip: Boolean;
    FOnClipClick: TNotifyEvent;
    function LevelY(ADb: Double): Integer;
  protected
    procedure PaintGL; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetLevels(APeakL, APeakR, AHoldL, AHoldR: Double; AClip: Boolean);
    property OnClipClick: TNotifyEvent read FOnClipClick write FOnClipClick;
  end;

  TGLMixerStrip = class(TGLWidget)
  private
    FId: Integer;
    FName, FSub: string;
    FTint: TColor;
    FSelected, FIsMaster: Boolean;
    FShowIn, FShowOut, FShowSolo, FCanArm: Boolean;
    FSyncing: Boolean;
    FInserts: TArray<TMixInsertInfo>;
    FSends: TArray<string>;
    FRowSig: string;
    FRows: TList<TMixRow>;
    FCboIn, FCboOut: TMixCombo;
    FBtnM, FBtnS, FBtnR: TMixToggle;
    FPan: TMixPan;
    FFader: TMixFader;
    FMeter: TMixMeter;
    FLblDb, FLblPeak: TMixReadout;
    FDbText, FPeakText: string;
    FInsertMenu: TPopupMenu;
    FMoreMenu: TPopupMenu;            // lists every effect on the strip (the '+N more' row)
    FDragOver: TDragOverEvent;
    FDragDrop: TDragDropEvent;
    FHeaderDown: Boolean;
    FCollapsed: Boolean;
    FOnCollapse: TMixStripEvent;
    FOnSelect: TMixStripEvent;
    FOnFader, FOnPan: TMixStripValueEvent;
    FOnFlag: TMixStripFlagEvent;
    FOnInput, FOnOutput: TMixStripIdEvent;
    FOnAddFx, FOnAddSend: TMixStripPointEvent;
    FOnEditInsert, FOnSendClick: TMixStripIndexEvent;
    FOnClipReset: TMixStripEvent;
    FOnReorder: TMixStripIdEvent;
    procedure SetSelected(AValue: Boolean);
    procedure ChildMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure FaderChanged(Sender: TObject);
    procedure PanChanged(Sender: TObject);
    procedure FlagChanged(Sender: TObject);
    procedure InputPicked(Sender: TObject);
    procedure OutputPicked(Sender: TObject);
    procedure ClipClicked(Sender: TObject);
    procedure RowClicked(Sender: TObject);
    procedure ShowMoreMenu(const AScreenPt: TPoint);
    procedure MoreItemClicked(Sender: TObject);
    procedure ClearRows;
    procedure BuildRows(AFxTop, AFxLimit: Integer);
    procedure ApplyHandlers(AControl: TControl);
    procedure SetInsertMenu(AValue: TPopupMenu);
    procedure FillCombo(ACombo: TGLCombo; const ATexts: TArray<string>;
      const AIds: TArray<Integer>; ASel: Integer);
    procedure DoSelect;
    function ArrowHit(X, Y: Integer): Boolean;
  protected
    procedure PaintGL; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { structure: names, tint, routing choices, the effect and send lists }
    procedure Configure(const AInfo: TMixStripInfo);
    { the moving values: fader, pan, M/S/R, meters }
    procedure UpdateLive(const ALive: TMixStripLive);
    procedure DoLayout;
    procedure SetDragHandlers(AOver: TDragOverEvent; ADrop: TDragDropEvent);
    { folds the strip to a slim bar (its owner sets the width) or opens it again; no event }
    procedure SetCollapsed(AValue: Boolean);
    property Collapsed: Boolean read FCollapsed;
    { the user folded or opened the strip with its header arrow }
    property OnCollapse: TMixStripEvent read FOnCollapse write FOnCollapse;
    property StripId: Integer read FId;
    property Selected: Boolean read FSelected write SetSelected;
    property IsMaster: Boolean read FIsMaster;
    property InsertMenu: TPopupMenu read FInsertMenu write SetInsertMenu;
    property OnSelect: TMixStripEvent read FOnSelect write FOnSelect;
    property OnFader: TMixStripValueEvent read FOnFader write FOnFader;
    property OnPan: TMixStripValueEvent read FOnPan write FOnPan;
    property OnFlag: TMixStripFlagEvent read FOnFlag write FOnFlag;
    property OnInput: TMixStripIdEvent read FOnInput write FOnInput;
    property OnOutput: TMixStripIdEvent read FOnOutput write FOnOutput;
    property OnAddFx: TMixStripPointEvent read FOnAddFx write FOnAddFx;
    property OnAddSend: TMixStripPointEvent read FOnAddSend write FOnAddSend;
    property OnEditInsert: TMixStripIndexEvent read FOnEditInsert write FOnEditInsert;
    property OnSendClick: TMixStripIndexEvent read FOnSendClick write FOnSendClick;
    property OnClipReset: TMixStripEvent read FOnClipReset write FOnClipReset;
    { AId = the strip id the header was dropped over, 0 when over none }
    property OnReorder: TMixStripIdEvent read FOnReorder write FOnReorder;
  end;

implementation

const
  PAD = 6;
  ROW_H = 20;
  ROW_STEP = 23;
  FADER_W = 38;
  HEADER_H = 40;
  FADER_MIN_H = 120;
  ARROW_W = 28;              { header area that folds / opens the strip }

function Blend(A, B: TColor; T: Double): TColor;
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

function FaceColorOf: TColor;
begin
  Result := CurrentTheme.PanelBackground;
end;

function FieldColorOf: TColor;
begin
  Result := Blend(CurrentTheme.PanelBackground, CurrentTheme.Background, 0.6);
end;

function Fit(cv: TGLCanvas; const S: string; AWidth: Integer): string;
begin
  Result := S;
  while (cv.TextWidth(Result) > AWidth) and (Length(Result) > 1) do
    Delete(Result, Length(Result), 1);
end;

function DbText(ADb: Double): string;
begin
  if ADb <= -90 then Result := '-inf'
  else Result := FormatFloat('0.0', ADb);
end;

{ TMixRow }

constructor TMixRow.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Height := ROW_H;
  FIndex := -1;
  FTint := clGray;
  TabStop := False;
end;

procedure TMixRow.PaintGL;
var
  cv: TGLCanvas;
  th: TUDAWTheme;
  face, fld, edge, ink: TColor;
  tw, y: Integer;
  s: string;
begin
  cv := GL;
  th := CurrentTheme;
  face := FaceColorOf;
  ink := th.Text;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := face;
  cv.FillRect(Rect(0, 0, Width, Height));
  fld := FieldColorOf;
  if Hover then fld := Blend(fld, th.Text, 0.10);
  if Pressed and Hover then fld := Blend(fld, th.Accent, 0.30);
  cv.Brush.Color := fld;
  cv.RoundRect(0, 0, Width, Height, 6, 6);
  edge := Blend(fld, th.Border, 0.9);
  cv.Pen.Style := psSolid;
  cv.Pen.Color := edge;
  cv.Brush.Style := bsClear;
  cv.RoundRect(0, 0, Width, Height, 6, 6);
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;

  cv.Font.Size := 8;
  y := (Height - cv.TextHeight('Ag')) div 2;
  case FKind of
    rkEffect, rkSend:
      begin
        if FKind = rkEffect then
        begin
          if FBypass then cv.Brush.Color := th.SecondaryText else cv.Brush.Color := th.Meter;
          cv.Ellipse(7, Height div 2 - 3, 13, Height div 2 + 3);
        end
        else
        begin
          cv.Brush.Color := th.SecondaryText;
          cv.Polygon([Point(7, Height div 2 - 3), Point(7, Height div 2 + 3), Point(13, Height div 2)]);
        end;
        cv.Brush.Style := bsClear;
        if FBypass then cv.Font.Color := th.SecondaryText else cv.Font.Color := ink;
        s := Fit(cv, Caption, Width - 22);
        cv.TextOut(18, y, s);
      end;
  else
    begin
      cv.Brush.Style := bsClear;
      cv.Font.Color := th.SecondaryText;
      s := Fit(cv, Caption, Width - 8);
      tw := cv.TextWidth(s);
      cv.TextOut((Width - tw) div 2, y, s);
    end;
  end;
end;

{ TMixReadout }

constructor TMixReadout.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  SharedSurface := True;
  Width := 50;
  Height := 20;
end;

procedure TMixReadout.PaintGL;
var
  cv: TGLCanvas;
  th: TUDAWTheme;
  fld: TColor;
  s: string;
begin
  cv := GL;
  th := CurrentTheme;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := FaceColorOf;
  cv.FillRect(Rect(0, 0, Width, Height));
  fld := FieldColorOf;
  cv.Brush.Color := fld;
  cv.RoundRect(0, 0, Width, Height, 6, 6);
  cv.Pen.Style := psSolid;
  cv.Pen.Color := Blend(fld, th.Border, 0.9);
  cv.Brush.Style := bsClear;
  cv.RoundRect(0, 0, Width, Height, 6, 6);
  cv.Pen.Style := psClear;
  cv.Font.Size := 8;
  cv.Font.Color := th.Text;
  s := Caption;
  cv.TextOut((Width - cv.TextWidth(s)) div 2, (Height - cv.TextHeight(s)) div 2, s);
end;

{ TMixCombo }

procedure TMixCombo.PaintGL;
var
  cv: TGLCanvas;
  th: TUDAWTheme;
  fld: TColor;
  s: string;
  cy: Integer;
begin
  cv := GL;
  th := CurrentTheme;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := FaceColorOf;
  cv.FillRect(Rect(0, 0, Width, Height));
  fld := FieldColorOf;
  if Hover or DroppedDown then fld := Blend(fld, th.Text, 0.10);
  cv.Brush.Color := fld;
  cv.RoundRect(0, 0, Width, Height, 6, 6);
  cv.Pen.Style := psSolid;
  cv.Pen.Color := Blend(fld, th.Border, 0.9);
  cv.Brush.Style := bsClear;
  cv.RoundRect(0, 0, Width, Height, 6, 6);
  cv.Pen.Style := psClear;
  cv.Font.Size := 8;
  cv.Font.Color := th.Text;
  if (ItemIndex >= 0) and (ItemIndex < Items.Count) then s := Items[ItemIndex] else s := '';
  s := Fit(cv, s, Width - 26);
  cv.TextOut(8, (Height - cv.TextHeight('Ag')) div 2, s);
  cy := Height div 2;
  cv.Brush.Style := bsSolid;
  cv.Brush.Color := th.SecondaryText;
  cv.Polygon([Point(Width - 17, cy - 2), Point(Width - 9, cy - 2), Point(Width - 13, cy + 3)]);
end;

{ TMixToggle }

constructor TMixToggle.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Toggle := True;
  TabStop := False;
  Width := 28;
  Height := 22;
  FLit := $0030C0F0;
end;

procedure TMixToggle.PaintGL;
var
  cv: TGLCanvas;
  th: TUDAWTheme;
  fld, ink: TColor;
  tw, cx, cy: Integer;
begin
  cv := GL;
  th := CurrentTheme;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := FaceColorOf;
  cv.FillRect(Rect(0, 0, Width, Height));
  fld := FieldColorOf;
  if Down then
  begin
    fld := FLit;
    ink := clWhite;
  end
  else
  begin
    if Hover then fld := Blend(fld, th.Text, 0.12);
    if Pressed and Hover then fld := Blend(fld, th.Accent, 0.3);
    ink := th.SecondaryText;
  end;
  cv.Brush.Color := fld;
  cv.RoundRect(0, 0, Width, Height, 6, 6);
  cv.Pen.Style := psSolid;
  cv.Pen.Color := Blend(fld, th.Border, 0.9);
  cv.Brush.Style := bsClear;
  cv.RoundRect(0, 0, Width, Height, 6, 6);
  cv.Pen.Style := psClear;
  if FGlyph = mgText then
  begin
    cv.Font.Size := 8;
    cv.Font.Style := [fsBold];
    cv.Font.Color := ink;
    tw := cv.TextWidth(Caption);
    cv.TextOut((Width - tw) div 2, (Height - cv.TextHeight(Caption)) div 2, Caption);
    Exit;
  end;

  { the icon, centred: a speaker (with a cross when muted, sound waves when not), headphones for
    solo, a disc for record }
  cx := Width div 2;
  cy := Height div 2;
  cv.Brush.Style := bsSolid;
  cv.Brush.Color := ink;
  cv.Pen.Style := psSolid;
  cv.Pen.Color := ink;
  cv.Pen.Width := 2;
  case FGlyph of
    mgMute:
      begin
        cv.Pen.Width := 1;
        cv.FillRect(Rect(cx - 7, cy - 2, cx - 3, cy + 3));
        cv.Polygon([Point(cx - 3, cy - 2), Point(cx + 1, cy - 6), Point(cx + 1, cy + 6), Point(cx - 3, cy + 3)]);
        cv.Pen.Width := 2;
        if Down then
        begin
          cv.MoveTo(cx + 3, cy - 3); cv.LineTo(cx + 9, cy + 3);
          cv.MoveTo(cx + 9, cy - 3); cv.LineTo(cx + 3, cy + 3);
        end
        else
        begin
          cv.MoveTo(cx + 4, cy - 3); cv.LineTo(cx + 6, cy); cv.LineTo(cx + 4, cy + 3);
          cv.MoveTo(cx + 7, cy - 6); cv.LineTo(cx + 10, cy); cv.LineTo(cx + 7, cy + 6);
        end;
      end;
    mgSolo:
      begin
        cv.MoveTo(cx - 6, cy + 2); cv.LineTo(cx - 6, cy - 2); cv.LineTo(cx - 3, cy - 6);
        cv.LineTo(cx + 3, cy - 6); cv.LineTo(cx + 6, cy - 2); cv.LineTo(cx + 6, cy + 2);
        cv.Pen.Width := 1;
        cv.FillRect(Rect(cx - 8, cy, cx - 3, cy + 6));
        cv.FillRect(Rect(cx + 3, cy, cx + 8, cy + 6));
      end;
    mgRecord:
      begin
        cv.Pen.Width := 1;
        cv.Ellipse(cx - 6, cy - 6, cx + 6, cy + 6);
      end;
  end;
  cv.Pen.Width := 1;
end;

{ TMixFader }

constructor TMixFader.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Vertical := True;
  Min := MIX_DB_MIN;
  Max := MIX_DB_MAX;
  DefaultPosition := 0;
  Decimals := 1;
  Width := FADER_W;
  Height := 200;
end;

procedure TMixFader.PaintGL;
var
  cv: TGLCanvas;
  th: TUDAWTheme;
  cx, top, bot, y, db, capY: Integer;
  cap: TColor;
begin
  cv := GL;
  th := CurrentTheme;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := FaceColorOf;
  cv.FillRect(Rect(0, 0, Width, Height));
  cx := Width div 2;
  top := 8;
  bot := Height - 8;   { the same travel TGLSlider.DragTo maps the pointer onto }
  cv.Brush.Color := FieldColorOf;
  cv.RoundRect(cx - 3, top - 4, cx + 3, bot + 4, 4, 4);

  { 6 dB ticks either side of the groove, the 0 dB mark longer and lit }
  db := Round(MIX_DB_MAX);
  while db >= Round(MIX_DB_MIN) do
  begin
    y := bot - Round((bot - top) * (db - MIX_DB_MIN) / (MIX_DB_MAX - MIX_DB_MIN));
    if db = 0 then
    begin
      cv.Pen.Style := psSolid;
      cv.Pen.Color := th.Meter;
      cv.MoveTo(cx - 17, y); cv.LineTo(cx - 5, y);
      cv.MoveTo(cx + 5, y); cv.LineTo(cx + 17, y);
    end
    else
    begin
      cv.Pen.Style := psSolid;
      cv.Pen.Color := Blend(FaceColorOf, th.SecondaryText, 0.45);
      cv.MoveTo(cx - 12, y); cv.LineTo(cx - 5, y);
      cv.MoveTo(cx + 5, y); cv.LineTo(cx + 12, y);
    end;
    Dec(db, 6);
  end;
  cv.Pen.Style := psClear;

  capY := bot - Round((bot - top) * Fraction);
  cap := Blend(FaceColorOf, th.Text, 0.55);
  GLDrawSliderKnob(cv, Rect(cx - 15, capY - 9, cx + 15, capY + 9), cap, Hover or Pressed, True);
  DrawFocus(cv);
end;

{ TMixPan }

constructor TMixPan.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Min := -1;
  Max := 1;
  DefaultPosition := 0;
  Decimals := 2;
  Height := 16;
  FTint := $00D8864A;
end;

procedure TMixPan.SetTint(AValue: TColor);
begin
  if FTint = AValue then Exit;
  FTint := AValue;
  Invalidate;
end;

procedure TMixPan.PaintGL;
var
  cv: TGLCanvas;
  th: TUDAWTheme;
  l, r, cy, mid, tx: Integer;
begin
  cv := GL;
  th := CurrentTheme;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := FaceColorOf;
  cv.FillRect(Rect(0, 0, Width, Height));
  l := 8;
  r := Width - 8;   { TGLSlider.DragTo's horizontal travel }
  cy := Height div 2;
  mid := (l + r) div 2;
  cv.Brush.Color := FieldColorOf;
  cv.RoundRect(l, cy - 2, r, cy + 2, 4, 4);
  tx := l + Round((r - l) * Fraction);
  cv.Brush.Color := FTint;
  if tx > mid then cv.FillRect(Rect(mid, cy - 2, tx, cy + 2))
  else if tx < mid then cv.FillRect(Rect(tx, cy - 2, mid, cy + 2));
  cv.Pen.Style := psSolid;
  cv.Pen.Color := th.SecondaryText;
  cv.MoveTo(mid, cy - 6); cv.LineTo(mid, cy + 6);
  cv.Pen.Style := psClear;
  GLDrawSliderKnob(cv, Rect(tx - 5, cy - 8, tx + 5, cy + 8), Blend(FaceColorOf, th.Text, 0.6),
    Hover or Pressed, False);
  DrawFocus(cv);
end;

{ TMixMeter }

constructor TMixMeter.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  SharedSurface := True;
  FPeakL := -120; FPeakR := -120; FHoldL := -120; FHoldR := -120;
  Width := 60;
  Height := 200;
end;

function TMixMeter.LevelY(ADb: Double): Integer;
var
  f: Double;
begin
  f := EnsureRange((ADb - MIX_DB_MIN) / (MIX_DB_MAX - MIX_DB_MIN), 0, 1);
  Result := (Height - 8) - Round((Height - 16) * f);
end;

procedure TMixMeter.SetLevels(APeakL, APeakR, AHoldL, AHoldR: Double; AClip: Boolean);
  function Q(AValue: Double): Double;
  begin
    Result := Round(EnsureRange(AValue, -120, 12) * 2) / 2;   { half-dB steps: below a pixel }
  end;
begin
  APeakL := Q(APeakL); APeakR := Q(APeakR); AHoldL := Q(AHoldL); AHoldR := Q(AHoldR);
  if (APeakL = FPeakL) and (APeakR = FPeakR) and (AHoldL = FHoldL) and
     (AHoldR = FHoldR) and (AClip = FClip) then Exit;
  FPeakL := APeakL; FPeakR := APeakR; FHoldL := AHoldL; FHoldR := AHoldR;
  FClip := AClip;
  Invalidate;
end;

procedure TMixMeter.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button = mbLeft) and (Y < 8) and Assigned(FOnClipClick) then FOnClipClick(Self);
end;

procedure TMixMeter.PaintGL;
var
  cv: TGLCanvas;
  th: TUDAWTheme;
  db, y, lx, rx, bw, bot, k, step: Integer;
  txt: string;

  procedure Bar(AX: Integer; APeak, AHold: Double);
  var
    top, yMinus6, yZero: Integer;
  begin
    cv.Brush.Style := bsSolid;
    cv.Pen.Style := psClear;
    cv.Brush.Color := FieldColorOf;
    cv.FillRect(Rect(AX, 8, AX + bw, bot));
    top := LevelY(APeak);
    if top >= bot then Exit;
    yMinus6 := LevelY(-6);
    yZero := LevelY(0);
    cv.Brush.Color := th.Meter;
    cv.FillRect(Rect(AX, Max(top, yMinus6), AX + bw, bot));
    if top < yMinus6 then
    begin
      cv.Brush.Color := $0020D0F0;
      cv.FillRect(Rect(AX, Max(top, yZero), AX + bw, yMinus6));
    end;
    if top < yZero then
    begin
      cv.Brush.Color := th.MeterClip;
      cv.FillRect(Rect(AX, top, AX + bw, yZero));
    end;
    if AHold > MIX_DB_MIN then
    begin
      cv.Pen.Style := psSolid;
      cv.Pen.Color := th.Text;
      k := LevelY(AHold);
      cv.MoveTo(AX, k); cv.LineTo(AX + bw, k);
      cv.Pen.Style := psClear;
    end;
  end;

begin
  cv := GL;
  th := CurrentTheme;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := FaceColorOf;
  cv.FillRect(Rect(0, 0, Width, Height));
  bw := 7;
  rx := Width - 2 - bw;
  lx := rx - bw - 2;
  bot := Height - 8;

  cv.Font.Size := 7;
  { a label every 6 dB when there is room for it, else every 12 or 24 }
  step := 6 * Max(1, Ceil(12 / Max(1, (Height - 16) * 6 / (MIX_DB_MAX - MIX_DB_MIN))));
  db := Round(MIX_DB_MAX);
  while db >= -54 do
  begin
    y := LevelY(db);
    if db = 0 then txt := '0'
    else if db > 0 then txt := '+' + IntToStr(db)
    else txt := IntToStr(db);
    cv.Brush.Style := bsClear;
    cv.Font.Color := th.SecondaryText;
    cv.TextOut(lx - 4 - cv.TextWidth(txt), y - cv.TextHeight(txt) div 2, txt);
    Dec(db, step);
  end;
  cv.Font.Color := th.SecondaryText;
  cv.TextOut(lx - 4 - cv.TextWidth('db'), bot - cv.TextHeight('db') div 2, 'db');

  Bar(lx, FPeakL, FHoldL);
  Bar(rx, FPeakR, FHoldR);

  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  if FClip then cv.Brush.Color := th.MeterClip
  else cv.Brush.Color := Blend(FieldColorOf, th.SecondaryText, 0.25);
  cv.FillRect(Rect(lx, 1, rx + bw, 6));
end;

{ TGLMixerStrip }

constructor TGLMixerStrip.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FRows := TList<TMixRow>.Create;
  FTint := $00D8864A;
  FId := -1;
  Width := 112;
  Height := 560;

  FCboIn := TMixCombo.Create(Self);
  FCboIn.Parent := Self;
  FCboIn.Hint := 'Input: the Timeline track this strip plays';
  FCboIn.ShowHint := True;
  FCboIn.OnChange := InputPicked;

  FCboOut := TMixCombo.Create(Self);
  FCboOut.Parent := Self;
  FCboOut.Hint := 'Output: where this strip is sent (Master or a bus / aux)';
  FCboOut.ShowHint := True;
  FCboOut.OnChange := OutputPicked;

  FPan := TMixPan.Create(Self);
  FPan.Parent := Self;
  FPan.Hint := 'Pan (double-click centres it, Shift drags finely)';
  FPan.ShowHint := True;
  FPan.OnChange := PanChanged;

  FLblDb := TMixReadout.Create(Self);
  FLblDb.Parent := Self;
  FLblDb.Hint := 'Fader level in dB';
  FLblDb.ShowHint := True;

  FLblPeak := TMixReadout.Create(Self);
  FLblPeak.Parent := Self;
  FLblPeak.Hint := 'Loudest peak since reset (dBFS)';
  FLblPeak.ShowHint := True;

  FFader := TMixFader.Create(Self);
  FFader.Parent := Self;
  FFader.Hint := 'Fader (double-click resets to 0 dB, Shift drags finely)';
  FFader.ShowHint := True;
  FFader.OnChange := FaderChanged;

  FMeter := TMixMeter.Create(Self);
  FMeter.Parent := Self;
  FMeter.Hint := 'Peak meter; click the cap at the top to clear the clip indicator';
  FMeter.ShowHint := True;
  FMeter.OnClipClick := ClipClicked;

  FBtnM := TMixToggle.Create(Self);
  FBtnM.Parent := Self;
  FBtnM.Caption := 'M';
  FBtnM.Glyph := mgMute;
  FBtnM.Hint := 'Mute this strip';
  FBtnM.ShowHint := True;
  FBtnM.Tag := 0;
  FBtnM.LitColor := $004060E8;
  FBtnM.OnChange := FlagChanged;

  FBtnS := TMixToggle.Create(Self);
  FBtnS.Parent := Self;
  FBtnS.Caption := 'S';
  FBtnS.Glyph := mgSolo;
  FBtnS.Hint := 'Solo this strip';
  FBtnS.ShowHint := True;
  FBtnS.Tag := 1;
  FBtnS.LitColor := $0030B8E8;
  FBtnS.OnChange := FlagChanged;

  FBtnR := TMixToggle.Create(Self);
  FBtnR.Parent := Self;
  FBtnR.Caption := 'R';
  FBtnR.Glyph := mgRecord;
  FBtnR.Hint := 'Arm this strip for recording';
  FBtnR.ShowHint := True;
  FBtnR.Tag := 2;
  FBtnR.LitColor := $003030E0;
  FBtnR.OnChange := FlagChanged;

  ApplyHandlers(FCboIn); ApplyHandlers(FCboOut); ApplyHandlers(FPan);
  ApplyHandlers(FLblDb); ApplyHandlers(FLblPeak); ApplyHandlers(FFader);
  ApplyHandlers(FMeter); ApplyHandlers(FBtnM); ApplyHandlers(FBtnS); ApplyHandlers(FBtnR);
end;

destructor TGLMixerStrip.Destroy;
begin
  FRows.Free;
  inherited Destroy;
end;

{ every child also selects its strip when pressed, and forwards drops }
procedure TGLMixerStrip.ApplyHandlers(AControl: TControl);
begin
  if AControl is TGLView then
  begin
    TGLView(AControl).OnMouseDown := ChildMouseDown;
    TGLView(AControl).OnDragOver := FDragOver;
    TGLView(AControl).OnDragDrop := FDragDrop;
  end;
end;

procedure TGLMixerStrip.SetDragHandlers(AOver: TDragOverEvent; ADrop: TDragDropEvent);
var
  i: Integer;
begin
  FDragOver := AOver;
  FDragDrop := ADrop;
  OnDragOver := AOver;
  OnDragDrop := ADrop;
  for i := 0 to ControlCount - 1 do
    ApplyHandlers(Controls[i]);
end;

procedure TGLMixerStrip.SetInsertMenu(AValue: TPopupMenu);
var
  r: TMixRow;
begin
  FInsertMenu := AValue;
  for r in FRows do
    if r.Kind = rkEffect then r.PopupMenu := AValue;
end;

procedure TGLMixerStrip.SetSelected(AValue: Boolean);
begin
  if FSelected = AValue then Exit;
  FSelected := AValue;
  Invalidate;
end;

procedure TGLMixerStrip.DoSelect;
begin
  if (not FSelected) and Assigned(FOnSelect) then FOnSelect(Self);
end;

procedure TGLMixerStrip.ChildMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  DoSelect;
end;

procedure TGLMixerStrip.FillCombo(ACombo: TGLCombo; const ATexts: TArray<string>;
  const AIds: TArray<Integer>; ASel: Integer);
var
  i: Integer;
begin
  ACombo.Items.BeginUpdate;
  try
    ACombo.Items.Clear;
    for i := 0 to High(ATexts) do
      ACombo.Items.AddObject(ATexts[i], TObject(NativeInt(AIds[i])));
  finally
    ACombo.Items.EndUpdate;
  end;
  ACombo.ItemIndex := ASel;
end;

procedure TGLMixerStrip.Configure(const AInfo: TMixStripInfo);
begin
  FId := AInfo.Id;
  FName := AInfo.Name;
  FSub := AInfo.Sub;
  FTint := AInfo.Tint;
  FIsMaster := AInfo.IsMaster;
  FShowIn := AInfo.ShowIn;
  FShowOut := AInfo.ShowOut;
  FShowSolo := AInfo.ShowSolo;
  FCanArm := AInfo.CanArm;
  FInserts := AInfo.Inserts;
  FSends := AInfo.Sends;
  FSelected := AInfo.Selected;
  FPan.Tint := FTint;
  FBtnS.Visible := FShowSolo;
  FBtnR.Visible := FCanArm;
  FSyncing := True;
  try
    FillCombo(FCboIn, AInfo.InTexts, AInfo.InIds, AInfo.InSel);
    FillCombo(FCboOut, AInfo.OutTexts, AInfo.OutIds, AInfo.OutSel);
  finally
    FSyncing := False;
  end;
  FRowSig := '';
  DoLayout;
  Invalidate;
end;

procedure TGLMixerStrip.UpdateLive(const ALive: TMixStripLive);
var
  peak: Double;
  t: string;
begin
  FSyncing := True;
  try
    FFader.Position := ALive.FaderDb;
    FPan.Position := ALive.Pan;
    FBtnM.Down := ALive.Muted;
    FBtnS.Down := ALive.Soloed;
    FBtnR.Down := ALive.Armed;
  finally
    FSyncing := False;
  end;
  t := DbText(ALive.FaderDb);
  if t <> FDbText then
  begin
    FDbText := t;
    FLblDb.Caption := t;
  end;
  peak := Max(ALive.PeakL, ALive.PeakR);
  t := DbText(peak);
  if t <> FPeakText then
  begin
    FPeakText := t;
    FLblPeak.Caption := t;
  end;
  FMeter.SetLevels(ALive.PeakL, ALive.PeakR, ALive.HoldL, ALive.HoldR, ALive.Clip);
end;

procedure TGLMixerStrip.FaderChanged(Sender: TObject);
begin
  if FSyncing or not Assigned(FOnFader) then Exit;
  FOnFader(Self, Round(FFader.Position * 10) / 10);
end;

procedure TGLMixerStrip.PanChanged(Sender: TObject);
var
  p: Double;
begin
  if FSyncing or not Assigned(FOnPan) then Exit;
  p := Round(FPan.Position * 100) / 100;
  if Abs(p) < 0.03 then p := 0;   { a detent at centre }
  FOnPan(Self, p);
end;

procedure TGLMixerStrip.FlagChanged(Sender: TObject);
begin
  if FSyncing or not Assigned(FOnFlag) then Exit;
  FOnFlag(Self, TControl(Sender).Tag, TGLButton(Sender).Down);
end;

procedure TGLMixerStrip.InputPicked(Sender: TObject);
begin
  if FSyncing or not Assigned(FOnInput) or (FCboIn.ItemIndex < 0) then Exit;
  FOnInput(Self, Integer(NativeInt(FCboIn.Items.Objects[FCboIn.ItemIndex])));
end;

procedure TGLMixerStrip.OutputPicked(Sender: TObject);
begin
  if FSyncing or not Assigned(FOnOutput) or (FCboOut.ItemIndex < 0) then Exit;
  FOnOutput(Self, Integer(NativeInt(FCboOut.Items.Objects[FCboOut.ItemIndex])));
end;

procedure TGLMixerStrip.ClipClicked(Sender: TObject);
begin
  DoSelect;
  if Assigned(FOnClipReset) then FOnClipReset(Self);
end;

{ the '+N more' row: a pop-up menu of EVERY effect on this strip; picking one opens its parameter window }
procedure TGLMixerStrip.ShowMoreMenu(const AScreenPt: TPoint);
var
  i: Integer;
  mi: TMenuItem;
begin
  if FMoreMenu = nil then FMoreMenu := TPopupMenu.Create(Self);
  FMoreMenu.Items.Clear;
  for i := 0 to High(FInserts) do
  begin
    mi := TMenuItem.Create(FMoreMenu);
    mi.Caption := Format('%d  %s%s', [i + 1, FInserts[i].Name, IfThen(FInserts[i].Bypass, '  (bypassed)', '')]);
    mi.Tag := i;
    mi.OnClick := MoreItemClicked;
    FMoreMenu.Items.Add(mi);
  end;
  GLShowPopup(FMoreMenu, AScreenPt.X, AScreenPt.Y);
end;

procedure TGLMixerStrip.MoreItemClicked(Sender: TObject);
begin
  if Assigned(FOnEditInsert) then FOnEditInsert(Self, TMenuItem(Sender).Tag);
end;

procedure TGLMixerStrip.RowClicked(Sender: TObject);
var
  r: TMixRow;
  pt: TPoint;
begin
  r := Sender as TMixRow;
  DoSelect;
  pt := r.ClientToScreen(Point(0, r.Height));
  case r.Kind of
    rkEffect:
      if Assigned(FOnEditInsert) then FOnEditInsert(Self, r.Index);
    rkMore:
      ShowMoreMenu(pt);
    rkAddFx:
      if Assigned(FOnAddFx) then FOnAddFx(Self, pt);
    rkSend:
      if Assigned(FOnSendClick) then FOnSendClick(Self, r.Index);
    rkAddSend:
      if Assigned(FOnAddSend) then FOnAddSend(Self, pt);
  end;
end;

procedure TGLMixerStrip.ClearRows;
var
  r: TMixRow;
begin
  for r in FRows do r.Free;
  FRows.Clear;
end;

{ effects, + FX, sends, + Send - the + buttons always stay; when the strip is
  too short for every row, the effect list ends in a "+N more" row }
procedure TGLMixerStrip.BuildRows(AFxTop, AFxLimit: Integer);
var
  cap, avail, nE, nS, shownE, shownS, i, y: Integer;
  sig: string;
  hiddenFrom: Integer;

  function AddRow(AKind: TMixRowKind; AIndex: Integer; const ACaption, AHint: string): TMixRow;
  begin
    Result := TMixRow.Create(Self);
    Result.Parent := Self;
    Result.SetBounds(PAD, y, Width - 2 * PAD, ROW_H);
    Result.Kind := AKind;
    Result.Index := AIndex;
    Result.Caption := ACaption;
    Result.Hint := AHint;
    Result.ShowHint := True;
    Result.Tint := FTint;
    Result.OnClick := RowClicked;
    ApplyHandlers(Result);
    if AKind = rkEffect then Result.PopupMenu := FInsertMenu;
    FRows.Add(Result);
    Inc(y, ROW_STEP);
  end;

begin
  cap := Max(3, (AFxLimit - AFxTop) div ROW_STEP);
  nE := Length(FInserts);
  nS := Length(FSends);
  avail := cap - 2;
  shownS := Min(nS, Max(0, avail div 3));
  shownE := Min(nE, avail - shownS);
  sig := Format('%d|%d|%d|%d|%d|%d', [Width, AFxTop, cap, shownE, shownS, FTint]);
  for i := 0 to nE - 1 do sig := sig + '|' + FInserts[i].Name + IntToStr(Ord(FInserts[i].Bypass));
  for i := 0 to nS - 1 do sig := sig + '|' + FSends[i];
  if sig = FRowSig then Exit;
  FRowSig := sig;
  ClearRows;
  y := AFxTop;
  hiddenFrom := -1;
  if shownE < nE then
  begin
    Dec(shownE);
    if shownE < 0 then shownE := 0;
    hiddenFrom := shownE;
  end;
  for i := 0 to shownE - 1 do
    AddRow(rkEffect, i, Format('%d  %s', [i + 1, FInserts[i].Name]),
      Format('%s - click to edit, right-click for more', [FInserts[i].Name])).Bypass := FInserts[i].Bypass;
  if hiddenFrom >= 0 then
    AddRow(rkMore, hiddenFrom, Format('+%d more', [nE - hiddenFrom]),
      'More effects than fit - click to list every effect on this strip');
  AddRow(rkAddFx, -1, '+ FX', 'Add an effect to this strip');
  for i := 0 to shownS - 1 do
    AddRow(rkSend, i, FSends[i], 'Send - click to remove it');
  AddRow(rkAddSend, -1, '+ Send', 'Send this strip to a bus or aux');
end;

procedure TGLMixerStrip.DoLayout;
var
  w, h, y, fxTop, fxLimit, btnTop, panTop, dbTop, fTop, fBot, innerW, btnW, half: Integer;
begin
  if FBtnR = nil then Exit;   { still constructing }
  if FCollapsed then
  begin
    for y := 0 to ControlCount - 1 do Controls[y].Visible := False;
    Invalidate;
    Exit;
  end;
  w := Width;
  h := Height;
  if (w <= 0) or (h <= 0) then Exit;
  innerW := w - 2 * PAD;
  y := HEADER_H;
  FCboIn.Visible := FShowIn;
  if FShowIn then
  begin
    FCboIn.SetBounds(PAD, y, innerW, 22);
    Inc(y, 26);
  end;
  FCboOut.Visible := FShowOut;
  if FShowOut then
  begin
    FCboOut.SetBounds(PAD, y, innerW, 22);
    Inc(y, 26);
  end;
  fxTop := y + 4;

  btnTop := h - PAD - 22;
  if FShowSolo or FCanArm then
  begin
    btnW := (innerW - 8) div 3;
    FBtnM.SetBounds(PAD, btnTop, btnW, 22);
    FBtnS.SetBounds(PAD + btnW + 4, btnTop, btnW, 22);
    FBtnR.SetBounds(PAD + 2 * (btnW + 4), btnTop, btnW, 22);
  end
  else
    FBtnM.SetBounds(PAD, btnTop, innerW, 22);

  fxLimit := h - (PAD + 22 + 8 + FADER_MIN_H + 10 + 20 + 6 + 16 + 6);
  if fxLimit < fxTop + 3 * ROW_STEP then fxLimit := fxTop + 3 * ROW_STEP;
  BuildRows(fxTop, fxLimit);

  panTop := fxLimit + 6;
  FPan.SetBounds(PAD, panTop, innerW, 16);
  dbTop := panTop + 22;
  half := (innerW - 4) div 2;
  FLblDb.SetBounds(PAD, dbTop, half, 20);
  FLblPeak.SetBounds(PAD + half + 4, dbTop, innerW - half - 4, 20);
  fTop := dbTop + 28;
  fBot := btnTop - 8;
  if fBot - fTop < 60 then fBot := fTop + 60;
  FFader.SetBounds(PAD + 2, fTop, FADER_W, fBot - fTop);
  FMeter.SetBounds(PAD + 2 + FADER_W + 2, fTop, w - PAD - (PAD + 2 + FADER_W + 2), fBot - fTop);
  Invalidate;
end;

procedure TGLMixerStrip.SetCollapsed(AValue: Boolean);
var
  i: Integer;
begin
  if FCollapsed = AValue then Exit;
  FCollapsed := AValue;
  if not FCollapsed then
  begin
    for i := 0 to ControlCount - 1 do Controls[i].Visible := True;
    FBtnS.Visible := FShowSolo;
    FBtnR.Visible := FCanArm;
    FRowSig := '';
  end;
  DoLayout;
  Invalidate;
end;

function TGLMixerStrip.ArrowHit(X, Y: Integer): Boolean;
begin
  if FCollapsed then Result := True
  else Result := (X >= Width - ARROW_W) and (Y < HEADER_H);
end;

procedure TGLMixerStrip.Resize;
begin
  inherited Resize;
  DoLayout;
end;

procedure TGLMixerStrip.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  DoSelect;
  FHeaderDown := (Button = mbLeft) and (Y < HEADER_H) and not ArrowHit(X, Y);
end;

{ a header drag drops the strip over another one: report where }
procedure TGLMixerStrip.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  p: TPoint;
  c: TControl;
  i: Integer;
begin
  inherited MouseUp(Button, Shift, X, Y);
  if (Button = mbLeft) and ArrowHit(X, Y) and PtInRect(Rect(0, 0, Width, Height), Point(X, Y)) then
  begin
    FHeaderDown := False;
    if Assigned(FOnCollapse) then FOnCollapse(Self);   // the owner stores the state and re-lays out
    Exit;
  end;
  if not FHeaderDown then Exit;
  FHeaderDown := False;
  if (Button <> mbLeft) or (Parent = nil) or not Assigned(FOnReorder) then Exit;
  p := ClientToParent(Point(X, Y));
  for i := 0 to Parent.ControlCount - 1 do
  begin
    c := Parent.Controls[i];
    if (c <> Self) and (c is TGLMixerStrip) and c.Visible and
       (p.X >= c.Left) and (p.X < c.Left + c.Width) then
    begin
      FOnReorder(Self, TGLMixerStrip(c).StripId);
      Exit;
    end;
  end;
end;

procedure TGLMixerStrip.PaintGL;
var
  cv: TGLCanvas;
  th: TUDAWTheme;
  face, edge: TColor;
begin
  cv := GL;
  th := CurrentTheme;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := th.Background;
  cv.FillRect(Rect(0, 0, Width, Height));
  face := FaceColorOf;
  if FIsMaster then face := Blend(face, th.Accent, 0.07);
  if FSelected then face := Blend(face, FTint, 0.14);
  cv.Brush.Color := face;
  cv.RoundRect(0, 0, Width, Height, 10, 10);

  { colour bar along the top edge }
  cv.Brush.Color := FTint;
  cv.RoundRect(0, 0, Width, 6, 6, 6);
  cv.Brush.Color := face;
  cv.FillRect(Rect(1, 3, Width - 1, 7));

  cv.Pen.Style := psSolid;
  if FSelected then
  begin
    cv.Pen.Color := FTint;
    cv.Pen.Width := 2;
  end
  else
  begin
    edge := th.Border;
    cv.Pen.Color := edge;
    cv.Pen.Width := 1;
  end;
  cv.Brush.Style := bsClear;
  cv.RoundRect(0, 0, Width, Height, 10, 10);
  cv.Pen.Width := 1;
  cv.Pen.Style := psClear;

  cv.Font.Size := 9;
  cv.Font.Style := [fsBold];
  cv.Font.Color := th.Text;
  if FCollapsed then
  begin
    { a slim bar: arrow pointing right, the name running down it }
    cv.Brush.Style := bsSolid;
    cv.Brush.Color := th.Text;
    cv.Polygon([Point(Width div 2 - 3, 14), Point(Width div 2 - 3, 26), Point(Width div 2 + 4, 20)]);
    cv.Brush.Style := bsClear;
    cv.PushClip(Rect(1, 32, Width - 1, Height - 4));
    cv.TextOutVertical(Width div 2 - cv.TextHeight(FName) div 2 - 1, 36, FName);
    cv.PopClip;
    cv.Font.Style := [];
    Exit;
  end;
  cv.TextOut(PAD + 1, 10, Fit(cv, FName, Width - 2 * PAD - 2 - 16));
  cv.Font.Style := [];
  cv.Font.Size := 8;
  cv.Font.Color := th.SecondaryText;
  cv.TextOut(PAD + 1, 25, Fit(cv, FSub, Width - 2 * PAD - 2));
  { fold arrow, top right }
  cv.Brush.Style := bsSolid;
  cv.Brush.Color := th.Text;
  cv.Polygon([Point(Width - 11, 14), Point(Width - 11, 26), Point(Width - 18, 20)]);
end;

end.
