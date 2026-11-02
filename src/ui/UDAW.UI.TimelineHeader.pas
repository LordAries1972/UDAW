unit UDAW.UI.TimelineHeader;

{ The Timeline's track header, built from UDAW's own OpenGL 3.3 widget set:
  a colour-coded avatar, the track name and sub-label, M / S / R toggles, a mini
  volume slider and a pan knob. One TGLTrackHeader per Timeline track, children of
  a TTlHeaderHost that sits over the header column of the Timeline canvas and
  clips them under the ruler as the tracks scroll.

  Like the mixer strip (UDAW.UI.MixerStrip) the header never touches the model:
  the Timeline tab feeds it through Configure (structure) and UpdateLive (values)
  and acts on its events. Presses on the header's own background are handed back
  through OnPassMouse in the host's coordinates, so track selection and the
  right-click track menu keep running through the Timeline's own mouse handlers. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Types, System.UITypes,
  System.Math, Vcl.Controls, Vcl.Graphics, UDAW.GL.Canvas, UDAW.GL.Widgets,
  UDAW.UI.ThemeColors, UDAW.UI.MixerStrip;

const
  TL_GAIN_MIN = -60.0;
  TL_GAIN_MAX = 6.0;

type
  TGLTrackHeader = class;

  TTlHeaderGlyph = (tgAudio, tgMidi, tgVideo, tgBus, tgOther);

  TTlHeaderInfo = record
    TrackId: Integer;
    Name: string;
    Tint: TColor;
    Glyph: TTlHeaderGlyph;
    CanArm, TempoUnknown: Boolean;
    NoMeter: Boolean;     // lanes that carry no audio (video) show no level meter
  end;

  TTlHeaderLive = record
    Sub: string;
    SubColor: TColor;     // clNone = the normal secondary text colour
    Muted, Soloed, Armed, Selected: Boolean;
    GainDb, Pan: Double;
    Level: Single;        // linear peak of what the track is playing right now, 0 when stopped
  end;

  TTlHeaderEvent = procedure(Sender: TGLTrackHeader) of object;
  TTlHeaderValueEvent = procedure(Sender: TGLTrackHeader; AValue: Double) of object;
  TTlHeaderFlagEvent = procedure(Sender: TGLTrackHeader; AFlag: Integer; AValue: Boolean) of object;
  TTlHeaderMouseEvent = procedure(Sender: TGLTrackHeader; ADown: Boolean; AButton: TMouseButton;
    AShift: TShiftState; X, Y: Integer) of object;

  { the clipping container the headers live in }
  TTlHeaderHost = class(TGLWidget)
  private
    FAddRect: TRect;
    FOnAddClick: TNotifyEvent;
    procedure SetAddRect(const AValue: TRect);
  protected
    procedure PaintGL; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    { the "+ Add channel" slot under the last header, in this widget's coordinates }
    property AddRect: TRect read FAddRect write SetAddRect;
    property OnAddClick: TNotifyEvent read FOnAddClick write FOnAddClick;
  end;

  TTlIcon = (tiMute, tiSolo, tiRecord, tiTempo);

  { a drawn-icon button for the lane header (no letters): speaker, headphones, record dot,
    and the question mark for an unknown tempo }
  TTlIconButton = class(TMixToggle)
  private
    FIcon: TTlIcon;
  protected
    procedure PaintGL; override;
  public
    constructor Create(AOwner: TComponent); override;
    property Icon: TTlIcon read FIcon write FIcon;
  end;

  TTlVolume = class(TGLSlider)
  private
    FTint: TColor;
    procedure SetTint(AValue: TColor);
  protected
    procedure PaintGL; override;
  public
    constructor Create(AOwner: TComponent); override;
    property Tint: TColor read FTint write SetTint;
  end;

  TTlPanKnob = class(TGLKnob)
  private
    FTint: TColor;
    procedure SetTint(AValue: TColor);
  protected
    procedure PaintGL; override;
  public
    constructor Create(AOwner: TComponent); override;
    property Tint: TColor read FTint write SetTint;
  end;

  TGLTrackHeader = class(TGLWidget)
  private
    FInfo: TTlHeaderInfo;
    FLive: TTlHeaderLive;
    FSyncing: Boolean;
    FMeter: Double;       // LED meter fraction 0..1 (fast attack, slow release)
    FLitLeds: Integer;
    FBtnM, FBtnS, FBtnR: TTlIconButton;
    FChipBpm: TTlIconButton;
    FVolume: TTlVolume;
    FPan: TTlPanKnob;
    FOnSelect, FOnTempoUnknown, FOnRename: TTlHeaderEvent;
    FOnGain, FOnPan: TTlHeaderValueEvent;
    FOnFlag: TTlHeaderFlagEvent;
    FOnPassMouse: TTlHeaderMouseEvent;
    procedure ChildMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure FlagChanged(Sender: TObject);
    procedure GainChanged(Sender: TObject);
    procedure PanChanged(Sender: TObject);
    procedure BpmClicked(Sender: TObject);
    function AvatarSize: Integer;
    function TitleRect: TRect;
    function GetTrackId: Integer;
  protected
    procedure PaintGL; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Configure(const AInfo: TTlHeaderInfo);
    procedure UpdateLive(const ALive: TTlHeaderLive);
    procedure DoLayout;
    property TrackId: Integer read GetTrackId;
    property OnSelect: TTlHeaderEvent read FOnSelect write FOnSelect;
    property OnTempoUnknown: TTlHeaderEvent read FOnTempoUnknown write FOnTempoUnknown;
    { double-click on the lane title: the owner asks for a new name }
    property OnRename: TTlHeaderEvent read FOnRename write FOnRename;
    property OnGain: TTlHeaderValueEvent read FOnGain write FOnGain;
    property OnPan: TTlHeaderValueEvent read FOnPan write FOnPan;
    property OnFlag: TTlHeaderFlagEvent read FOnFlag write FOnFlag;
    property OnPassMouse: TTlHeaderMouseEvent read FOnPassMouse write FOnPassMouse;
  end;

implementation


uses
  UDAW.DSP.MathTables;

const
  PAD = 10;
  LED_COUNT = 28;
  LED_H = 8;

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

function Fit(cv: TGLCanvas; const S: string; AWidth: Integer): string;
begin
  Result := S;
  while (cv.TextWidth(Result) > AWidth) and (Length(Result) > 1) do
    Delete(Result, Length(Result), 1);
end;

function HeaderFace: TColor;
begin
  Result := Blend(CurrentTheme.PanelBackground, CurrentTheme.Background, 0.15);
end;

function FieldFace: TColor;
begin
  Result := Blend(CurrentTheme.PanelBackground, CurrentTheme.Background, 0.6);
end;

{ TTlHeaderHost }

constructor TTlHeaderHost.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csAcceptsControls];
  Width := 142;
  Height := 200;
end;

procedure TTlHeaderHost.PaintGL;
begin
  GL.Brush.Style := bsSolid;
  GL.Pen.Style := psClear;
  GL.Brush.Color := CurrentTheme.Background;
  GL.FillRect(Rect(0, 0, Width, Height));
  if FAddRect.Right - FAddRect.Left > 8 then
  begin
    GL.Brush.Style := bsClear;
    GL.Pen.Style := psSolid;
    GL.Pen.Color := CurrentTheme.Border;
    GL.Pen.Style := psDash;
    GL.Rectangle(FAddRect.Left, FAddRect.Top, FAddRect.Right, FAddRect.Bottom);
    GL.Pen.Style := psSolid;
    GL.Font.Color := CurrentTheme.SecondaryText;
    GL.TextOut(FAddRect.Left + (FAddRect.Right - FAddRect.Left - GL.TextWidth('+ Add channel')) div 2,
      FAddRect.Top + (FAddRect.Bottom - FAddRect.Top - GL.TextHeight('+ Add channel')) div 2,
      '+ Add channel');
    GL.Brush.Style := bsSolid;
  end;
end;

procedure TTlHeaderHost.SetAddRect(const AValue: TRect);
begin
  if EqualRect(FAddRect, AValue) then Exit;
  FAddRect := AValue;
  Invalidate;
end;

procedure TTlHeaderHost.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button = mbLeft) and PtInRect(FAddRect, Point(X, Y)) and Assigned(FOnAddClick) then
    FOnAddClick(Self);
end;

{ TTlIconButton }

constructor TTlIconButton.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 24;
  Height := 20;
end;

procedure TTlIconButton.PaintGL;
var
  cv: TGLCanvas;
  th: TUDAWTheme;
  ink: TColor;
  cx, cy, k: Integer;
  a: Double;
  tw: Integer;
begin
  cv := GL;
  th := CurrentTheme;
  { no face and no border: just the icon on the header, in the header's own colour behind it; a lit
    (pressed-in) button shows its icon in its lit colour, a hovered one in the text colour }
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := HeaderFace;
  cv.FillRect(Rect(0, 0, Width, Height));
  if Down then ink := LitColor
  else if Hover then ink := th.Text
  else ink := th.SecondaryText;
  cx := Width shr 1;
  cy := Height shr 1;
  cv.Pen.Style := psSolid;
  cv.Pen.Color := ink;
  cv.Pen.Width := 1;
  cv.Brush.Style := bsSolid;
  cv.Brush.Color := ink;
  case FIcon of
    tiMute:
      begin
        { speaker; sound waves while audible, a cross while muted }
        cv.FillRect(Rect(cx - 7, cy - 2, cx - 3, cy + 3));
        cv.Polygon([Point(cx - 3, cy - 2), Point(cx + 1, cy - 6), Point(cx + 1, cy + 6), Point(cx - 3, cy + 3)]);
        cv.Pen.Width := 2;
        if Down then
        begin
          cv.MoveTo(cx + 3, cy - 3); cv.LineTo(cx + 8, cy + 3);
          cv.MoveTo(cx + 3, cy + 3); cv.LineTo(cx + 8, cy - 3);
        end
        else
        begin
          cv.MoveTo(cx + 3, cy - 3); cv.LineTo(cx + 5, cy); cv.LineTo(cx + 3, cy + 3);
          cv.MoveTo(cx + 5, cy - 6); cv.LineTo(cx + 8, cy); cv.LineTo(cx + 5, cy + 6);
        end;
      end;
    tiSolo:
      begin
        { headphones: the band over two ear cups }
        cv.Pen.Width := 2;
        for k := 0 to 11 do
        begin
          a := Pi + Pi * k / 11;
          if k = 0 then cv.MoveTo(cx + Round(FastCos(a) * 6), cy + 1 + Round(FastSin(a) * 6))
          else cv.LineTo(cx + Round(FastCos(a) * 6), cy + 1 + Round(FastSin(a) * 6));
        end;
        cv.Pen.Width := 1;
        cv.FillRect(Rect(cx - 8, cy + 1, cx - 3, cy + 7));
        cv.FillRect(Rect(cx + 4, cy + 1, cx + 9, cy + 7));
      end;
    tiRecord:
      begin
        if not Down then
        begin
          ink := Blend(ink, $003030E0, 0.75);
          cv.Pen.Color := ink;
          cv.Brush.Color := ink;
        end;
        cv.Ellipse(cx - 5, cy - 5, cx + 6, cy + 6);
      end;
    tiTempo:
      begin
        { the tempo of this lane is not known: a question mark }
        cv.Pen.Style := psClear;
        cv.Brush.Style := bsClear;
        cv.Font.Size := 10;
        cv.Font.Style := [fsBold];
        cv.Font.Color := Blend(ink, $0030B8E8, 0.6);
        tw := cv.TextWidth('?');
        cv.TextOut((Width - tw) div 2, (Height - cv.TextHeight('?')) div 2, '?');
      end;
  end;
  cv.Pen.Width := 1;
  cv.Pen.Style := psClear;
end;

{ TTlVolume }

constructor TTlVolume.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Min := TL_GAIN_MIN;
  Max := TL_GAIN_MAX;
  DefaultPosition := 0;
  Decimals := 1;
  Height := 16;
  FTint := $00D8864A;
end;

procedure TTlVolume.SetTint(AValue: TColor);
begin
  if FTint = AValue then Exit;
  FTint := AValue;
  Invalidate;
end;

procedure TTlVolume.PaintGL;
var
  cv: TGLCanvas;
  th: TUDAWTheme;
  l, r, cy, tx: Integer;
begin
  cv := GL;
  th := CurrentTheme;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := HeaderFace;
  cv.FillRect(Rect(0, 0, Width, Height));
  l := 8;
  r := Width - 8;   { TGLSlider.DragTo's horizontal travel }
  cy := Height shr 1;
  cv.Brush.Color := FieldFace;
  cv.RoundRect(l, cy - 3, r, cy + 3, 5, 5);
  tx := l + Round((r - l) * Fraction);
  cv.Brush.Color := Blend(FieldFace, FTint, 0.75);
  if tx > l then cv.RoundRect(l, cy - 3, tx, cy + 3, 5, 5);
  cv.Brush.Color := Blend(HeaderFace, th.Text, IfThen(Hover or Pressed, 0.75, 0.6));
  cv.RoundRect(tx - 3, cy - 6, tx + 3, cy + 6, 3, 3);
end;

{ TTlPanKnob }

constructor TTlPanKnob.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Min := -1;
  Max := 1;
  DefaultPosition := 0;
  Decimals := 2;
  Width := 32;
  Height := 32;
  FTint := $00D8864A;
end;

procedure TTlPanKnob.SetTint(AValue: TColor);
begin
  if FTint = AValue then Exit;
  FTint := AValue;
  Invalidate;
end;

procedure TTlPanKnob.PaintGL;
const
  A0 = 0.75 * Pi;
  SWEEP = 1.5 * Pi;
var
  cv: TGLCanvas;
  th: TUDAWTheme;
  cx, cy, r: Integer;
  aVal, aMid: Double;

  procedure Arc(AFrom, ATo: Double; AColor: TColor; AWidth: Integer);
  var
    k, steps: Integer;
    t0, t1: Double;
  begin
    steps := System.Math.Max(2, Round(Abs(ATo - AFrom) * r / 2));
    cv.Pen.Style := psSolid;
    cv.Pen.Width := AWidth;
    cv.Pen.Color := AColor;
    for k := 0 to steps - 1 do
    begin
      t0 := AFrom + (ATo - AFrom) * k / steps;
      t1 := AFrom + (ATo - AFrom) * (k + 1) / steps;
      cv.MoveTo(cx + Round(FastCos(t0) * r), cy + Round(FastSin(t0) * r));
      cv.LineTo(cx + Round(FastCos(t1) * r), cy + Round(FastSin(t1) * r));
    end;
    cv.Pen.Width := 1;
    cv.Pen.Style := psClear;
  end;

begin
  cv := GL;
  th := CurrentTheme;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := HeaderFace;
  cv.FillRect(Rect(0, 0, Width, Height));
  cx := Width shr 1;
  cy := Height shr 1;
  r := System.Math.Min(Width, Height) div 2 - 3;
  cv.Brush.Color := FieldFace;
  cv.Ellipse(cx - r + 3, cy - r + 3, cx + r - 2, cy + r - 2);
  aMid := A0 + SWEEP * 0.5;
  aVal := A0 + SWEEP * Fraction;
  Arc(A0, A0 + SWEEP, Blend(FieldFace, th.Border, 0.9), 2);
  if Abs(aVal - aMid) > 0.01 then Arc(aMid, aVal, FTint, 2);
  cv.Pen.Style := psSolid;
  cv.Pen.Color := IfThen(Hover or Pressed, th.Text, th.SecondaryText);
  cv.MoveTo(cx, cy);
  cv.LineTo(cx + Round(FastCos(aVal) * (r - 4)), cy + Round(FastSin(aVal) * (r - 4)));
  cv.Pen.Style := psClear;
end;

{ TGLTrackHeader }

constructor TGLTrackHeader.Create(AOwner: TComponent);
  procedure Wire(AButton: TTlIconButton; AIcon: TTlIcon; const AHint: string; ATag: Integer; ALit: TColor);
  begin
    AButton.Parent := Self;
    AButton.Icon := AIcon;
    AButton.Caption := '';
    AButton.Hint := AHint;
    AButton.ShowHint := True;
    AButton.Tag := ATag;
    AButton.LitColor := ALit;
    AButton.OnChange := FlagChanged;
    AButton.OnMouseDown := ChildMouseDown;
  end;
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csDoubleClicks];   { a double-click on the title renames the lane }
  Width := 142;
  Height := 80;
  FInfo.Tint := $00D8864A;
  FLive.SubColor := clNone;

  FBtnM := TTlIconButton.Create(Self);
  Wire(FBtnM, tiMute, 'Mute this track', 0, $004060E8);
  FBtnS := TTlIconButton.Create(Self);
  Wire(FBtnS, tiSolo, 'Solo this track', 1, $0030B8E8);
  FBtnR := TTlIconButton.Create(Self);
  Wire(FBtnR, tiRecord, 'Arm this track for recording', 2, $003030E0);

  FChipBpm := TTlIconButton.Create(Self);
  FChipBpm.Parent := Self;
  FChipBpm.Icon := tiTempo;
  FChipBpm.Toggle := False;
  FChipBpm.Hint := 'The tempo of this track is not known - click to enter it';
  FChipBpm.ShowHint := True;
  FChipBpm.OnClick := BpmClicked;
  FChipBpm.OnMouseDown := ChildMouseDown;

  FVolume := TTlVolume.Create(Self);
  FVolume.Parent := Self;
  FVolume.Hint := 'Track volume (double-click resets to 0 dB, Shift drags finely)';
  FVolume.ShowHint := True;
  FVolume.OnChange := GainChanged;
  FVolume.OnMouseDown := ChildMouseDown;

  FPan := TTlPanKnob.Create(Self);
  FPan.Parent := Self;
  FPan.Hint := 'Track pan (drag up or down, double-click centres it)';
  FPan.ShowHint := True;
  FPan.OnChange := PanChanged;
  FPan.OnMouseDown := ChildMouseDown;
end;

function TGLTrackHeader.GetTrackId: Integer;
begin
  Result := FInfo.TrackId;
end;

function TGLTrackHeader.AvatarSize: Integer;
begin
  Result := 20;
end;

procedure TGLTrackHeader.Configure(const AInfo: TTlHeaderInfo);
begin
  FInfo := AInfo;
  FBtnR.Visible := AInfo.CanArm;
  FChipBpm.Visible := AInfo.TempoUnknown;
  FVolume.Tint := AInfo.Tint;
  FPan.Tint := AInfo.Tint;
  DoLayout;
  Invalidate;
end;

procedure TGLTrackHeader.UpdateLive(const ALive: TTlHeaderLive);
var
  changed: Boolean;
  db, frac: Double;
  leds: Integer;
begin
  changed := (ALive.Sub <> FLive.Sub) or (ALive.SubColor <> FLive.SubColor) or
    (ALive.Selected <> FLive.Selected);
  { LED meter: -60..0 dB across the strip, instant rise, steady fall }
  if ALive.Level > 0.000001 then db := 20 * FastLog10(ALive.Level) else db := -90;
  frac := System.Math.EnsureRange((db + 60) / 60, 0, 1);
  if frac >= FMeter then FMeter := frac else FMeter := System.Math.Max(frac, FMeter - 0.07);
  leds := Round(FMeter * LED_COUNT);
  if leds <> FLitLeds then
  begin
    FLitLeds := leds;
    changed := True;
  end;
  FLive := ALive;
  FSyncing := True;
  try
    FBtnM.Down := ALive.Muted;
    FBtnS.Down := ALive.Soloed;
    FBtnR.Down := ALive.Armed;
    FVolume.Position := ALive.GainDb;
    FPan.Position := ALive.Pan;
  finally
    FSyncing := False;
  end;
  if changed then Invalidate;
end;

procedure TGLTrackHeader.ChildMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if (not FLive.Selected) and Assigned(FOnSelect) then FOnSelect(Self);
end;

procedure TGLTrackHeader.FlagChanged(Sender: TObject);
begin
  if FSyncing or not Assigned(FOnFlag) then Exit;
  FOnFlag(Self, TControl(Sender).Tag, TGLButton(Sender).Down);
end;

procedure TGLTrackHeader.GainChanged(Sender: TObject);
begin
  if FSyncing or not Assigned(FOnGain) then Exit;
  FOnGain(Self, Round(FVolume.Position * 10) / 10);
end;

procedure TGLTrackHeader.PanChanged(Sender: TObject);
var
  p: Double;
begin
  if FSyncing or not Assigned(FOnPan) then Exit;
  p := Round(FPan.Position * 100) / 100;
  if Abs(p) < 0.04 then p := 0;
  FOnPan(Self, p);
end;

procedure TGLTrackHeader.BpmClicked(Sender: TObject);
begin
  if Assigned(FOnTempoUnknown) then FOnTempoUnknown(Self);
end;

{ top to bottom: the title row (BPM chip at its right when the tempo is unknown), the M / S / R
  buttons with the volume slider and pan knob, and the LED level meter along the bottom }
procedure TGLTrackHeader.DoLayout;
var
  w, h, btnW, ks, rowY, xVol: Integer;
  roomy: Boolean;
begin
  if FPan = nil then Exit;   { still constructing }
  w := Width;
  h := Height;
  if (w <= 0) or (h <= 0) then Exit;
  btnW := 24;
  rowY := 28;
  FBtnM.SetBounds(PAD, rowY, btnW, 20);
  FBtnS.SetBounds(PAD + btnW + 3, rowY, btnW, 20);
  FBtnR.SetBounds(PAD + 2 * (btnW + 3), rowY, btnW, 20);
  { the unknown-tempo question mark sits with the other icon buttons }
  FChipBpm.SetBounds(PAD + 3 * (btnW + 3), rowY, btnW, 20);
  roomy := h >= 64;
  FVolume.Visible := roomy;
  FPan.Visible := roomy;
  if roomy then
  begin
    ks := System.Math.Max(20, System.Math.Min(30, h - LED_H - 8 - rowY + 2));
    FPan.SetBounds(w - PAD - ks, rowY - (ks - 18) div 2, ks, ks);
    xVol := PAD + 3 * (btnW + 3) + 2;
    if FChipBpm.Visible then Inc(xVol, btnW + 3);
    FVolume.SetBounds(xVol, rowY + 1, System.Math.Max(30, w - PAD - ks - 6 - xVol), 18);
  end;
  Invalidate;
end;
procedure TGLTrackHeader.Resize;
begin
  inherited Resize;
  DoLayout;
end;

function TGLTrackHeader.TitleRect: TRect;
begin
  Result := Rect(PAD + AvatarSize + 6, 4, Width - PAD, 4 + AvatarSize + 2);
end;

procedure TGLTrackHeader.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button = mbLeft) and (ssDouble in Shift) and PtInRect(TitleRect, Point(X, Y)) and
     Assigned(FOnRename) then
  begin
    FOnRename(Self);
    Exit;
  end;
  if Assigned(FOnPassMouse) then FOnPassMouse(Self, True, Button, Shift, X, Y);
end;

procedure TGLTrackHeader.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if Assigned(FOnPassMouse) then FOnPassMouse(Self, False, Button, Shift, X, Y);
end;

procedure TGLTrackHeader.PaintGL;
var
  cv: TGLCanvas;
  th: TUDAWTheme;
  face: TColor;
  d, ax, ay, cx, cy, i, xText, nameW, nameEnd, subW, ledY: Integer;
  segW: Double;
  ledCol: TColor;
  nm: string;
  pts: TArray<TPoint>;
begin
  cv := GL;
  th := CurrentTheme;
  if FLive.Selected then face := Blend(th.Selection, th.PanelBackground, 0.6)
  else face := HeaderFace;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := face;
  cv.FillRect(Rect(0, 0, Width, Height));
  { colour stripe down the left edge, wider when selected }
  cv.Brush.Color := FInfo.Tint;
  cv.FillRect(Rect(0, 0, IfThen(FLive.Selected, 6, 3), Height));
  cv.Pen.Style := psSolid;
  cv.Pen.Color := th.Border;
  cv.MoveTo(0, Height - 1);
  cv.LineTo(Width, Height - 1);
  cv.Pen.Style := psClear;

  { avatar: tinted disc with a glyph for the kind of track }
  d := AvatarSize;
  ax := PAD;
  ay := 5;
  cx := ax + d div 2;
  cy := ay + d div 2;
  cv.Brush.Color := Blend(face, FInfo.Tint, 0.28);
  cv.Ellipse(ax, ay, ax + d, ay + d);
  cv.Pen.Style := psSolid;
  cv.Pen.Color := FInfo.Tint;
  cv.Pen.Width := 2;
  cv.Brush.Color := FInfo.Tint;
  case FInfo.Glyph of
    tgAudio:
      begin
        SetLength(pts, 0);
        for i := 0 to 12 do
        begin
          SetLength(pts, Length(pts) + 1);
          pts[High(pts)] := Point(ax + d div 5 + Round((d - 2 * (d div 5)) * i / 12),
            cy - Round(FastSin(i / 12 * 2 * Pi) * d * 0.2));
        end;
        for i := 0 to High(pts) - 1 do
        begin
          cv.MoveTo(pts[i].X, pts[i].Y);
          cv.LineTo(pts[i + 1].X, pts[i + 1].Y);
        end;
      end;
    tgMidi:
      begin
        cv.Pen.Style := psClear;
        for i := 0 to 3 do
          cv.FillRect(Rect(ax + d div 4 + i * (d div 6), cy - (2 + (i * 5) mod 7), ax + d div 4 + i * (d div 6) + 3, cy + 5));
      end;
    tgVideo:
      begin
        cv.Pen.Style := psClear;
        cv.FillRect(Rect(cx - d div 4, cy - d div 6, cx + d div 8, cy + d div 6));
        cv.Polygon([Point(cx + d div 8, cy), Point(cx + d div 4 + 1, cy - d div 6), Point(cx + d div 4 + 1, cy + d div 6)]);
      end;
    tgBus:
      begin
        cv.Brush.Style := bsClear;
        cv.Ellipse(cx - d div 5, cy - d div 5, cx + d div 5, cy + d div 5);
        cv.Brush.Style := bsSolid;
      end;
  else
    begin
      cv.Pen.Style := psClear;
      cv.Ellipse(cx - 3, cy - 3, cx + 3, cy + 3);
    end;
  end;
  cv.Pen.Width := 1;
  cv.Pen.Style := psClear;

  { title row: the name first; the sub-label to its right when there is room }
  xText := ax + d + 6;
  cv.Brush.Style := bsClear;
  cv.Font.Size := 9;
  cv.Font.Style := [fsBold];
  cv.Font.Color := th.Text;
  nameW := Width - PAD - xText;
  nm := Fit(cv, FInfo.Name, nameW);
  cv.TextOut(xText, ay + (d - cv.TextHeight('Ag')) div 2, nm);
  nameEnd := xText + cv.TextWidth(nm);
  cv.Font.Style := [];
  cv.Font.Size := 8;
  if FLive.SubColor <> clNone then cv.Font.Color := FLive.SubColor
  else cv.Font.Color := th.SecondaryText;
  if FLive.Sub <> '' then
  begin
    subW := cv.TextWidth(FLive.Sub);
    if Width - PAD - subW - nameEnd >= 10 then
      cv.TextOut(Width - PAD - subW, ay + (d - cv.TextHeight('Ag')) div 2 + 1, FLive.Sub);
  end;

  { LED level meter along the bottom: green, then amber, then red; dim when unlit }
  if (Height >= 50) and not FInfo.NoMeter then
  begin
    ledY := Height - LED_H - 6;
    segW := (Width - 2 * PAD) / LED_COUNT;
    cv.Pen.Style := psClear;
    for i := 0 to LED_COUNT - 1 do
    begin
      if i < LED_COUNT * 0.62 then ledCol := $0060D070
      else if i < LED_COUNT * 0.86 then ledCol := $0030C8F0
      else ledCol := $003030E0;
      if i < FLitLeds then cv.Brush.Color := ledCol
      else cv.Brush.Color := Blend(face, ledCol, 0.16);
      cv.FillRect(Rect(PAD + Round(i * segW), ledY, PAD + Round((i + 1) * segW) - 1, ledY + LED_H));
    end;
  end;
end;
end.
