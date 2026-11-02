unit UDAW.GL.Widgets;

{ UDAW's own OpenGL 3.3 control set, drawn with TGLCanvas on TGLView.

  Every widget is a designer-editable component (drop it on a form, set the
  published properties). All of them follow the active VCL style colours,
  show the standard Hint, and draw hover / pressed / disabled states.

    TGLButton    push or toggle button (Caption, Toggle, Down)
    TGLCheck     check box (Caption, Checked)
    TGLKnob      rotary control (Min, Max, Position, DefaultPosition, Caption, Decimals)
    TGLSlider    horizontal / vertical fader (Min, Max, Position, Vertical)
    TGLProgress  progress / level bar (Min, Max, Position, Vertical)
    TGLTabStrip  tab headers (Tabs, Hints, TabIndex)
    TGLScrollBar scroll bar (Min, Max, PageSize, Position, Vertical)
    TGLEdit      single-line text box (Text, ReadOnly, PasswordChar, MaxLength)
    TGLCombo     drop-down list (Items, ItemIndex)

  Knob and slider: drag (Shift = fine), mouse wheel, double-click resets to
  DefaultPosition. }

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes,
  System.Types, System.UITypes, System.Math, Vcl.Controls, Vcl.Graphics,
  Vcl.Forms, Vcl.Themes, Vcl.Clipbrd, Vcl.ExtCtrls, Vcl.ComCtrls, Vcl.StdCtrls, UDAW.GL.Canvas;

type
  TGLWidget = class(TGLView)
  private
    FHover: Boolean;
    FPressed: Boolean;
    FCaption: string;
    FGlow, FGlowPhase: Double;       // hover highlight: fade 0..1 and the shimmer / pulse phase
    FGlowTimer: TTimer;
    procedure GlowTick(Sender: TObject);
    function GetHint: string;
    procedure SetHint(const AValue: string);
    procedure SetCaption(const AValue: string);
    procedure CMMouseEnter(var Msg: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Msg: TMessage); message CM_MOUSELEAVE;
    procedure CMEnabledChanged(var Msg: TMessage); message CM_ENABLEDCHANGED;
  protected
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure KeyUp(var Key: Word; Shift: TShiftState); override;
    { Space on a focused button / check box }
    procedure Activate; virtual;
    procedure WMSetFocus(var Msg: TWMSetFocus); message WM_SETFOCUS;
    procedure WMKillFocus(var Msg: TWMKillFocus); message WM_KILLFOCUS;
    procedure DrawFocus(cv: TGLCanvas);
    { the menus' highlight on a control the pointer is over: a glowing accent pill that fades in,
      breathes, and has a slanted band of light sweeping across it }
    procedure DrawHoverGlow(cv: TGLCanvas; const R: TRect; ARadius: Integer);
    { only controls that show the highlight run its repaint timer; a panel hosting video must not
      be repainted over and over while the pointer rests on it }
    function WantsGlow: Boolean; virtual;
    { the theme's control colours (Settings > Colors > Control: ...) }
    function SelectionColor: TColor;
    function SelectionTextColor: TColor;
    function HoverTint: TColor;
    function FocusColor: TColor;
    procedure PrepareCanvas(ACanvas: TGLCanvas); override;
    function FieldColor: TColor;
    { Caption as displayed: '&&' -> '&', a single '&' (accelerator mark) removed }
    function ShownCaption: string;
    procedure CaptionChanged; virtual;
    function FaceColor: TColor;
    { the colour the widget sits on (a parent panel's own colour, else the face colour): a widget
      that must look transparent fills with it, since every widget paints into its own frame }
    function BackdropColor: TColor;
    function InkColor: TColor;
    function AccentColor: TColor;
    function TrackColor: TColor;
    property Hover: Boolean read FHover;
    property Pressed: Boolean read FPressed;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property Caption: string read FCaption write SetCaption;
    property Hint: string read GetHint write SetHint;
    property ParentShowHint;
    property Tag;
    property TabStop;
    property TabOrder;
    property OnEnter;
    property OnExit;
  end;

  TGLButton = class(TGLWidget)
  private
    FToggle: Boolean;
    FDown: Boolean;
    FDefault: Boolean;
    FOnChange: TNotifyEvent;
    procedure SetDown(AValue: Boolean);
    procedure CMDialogKey(var Msg: TCMDialogKey); message CM_DIALOGKEY;
  protected
    procedure PaintGL; override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure Activate; override;
    function WantsGlow: Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property TabStop default True;
    { Enter activates the button while the form is not otherwise using it }
    property Default: Boolean read FDefault write FDefault default False;
    property Toggle: Boolean read FToggle write FToggle default False;
    property Down: Boolean read FDown write SetDown default False;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  TGLCheck = class(TGLWidget)
  private
    FChecked: Boolean;
    FOnChange: TNotifyEvent;
    procedure SetChecked(AValue: Boolean);
  protected
    procedure PaintGL; override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure Activate; override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property TabStop default True;
    property Checked: Boolean read FChecked write SetChecked default False;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  { shared value model of knob and slider }
  TGLValueWidget = class(TGLWidget)
  private
    FMin, FMax, FPos, FDefault, FStep: Double;
    FDecimals: Integer;
    FOnChange: TNotifyEvent;
    FDragY, FDragX: Integer;
    FDragStart: Double;
    procedure SetMin(AValue: Double);
    procedure SetMax(AValue: Double);
    procedure SetPos(AValue: Double);
    procedure SetDecimals(AValue: Integer);
  protected
    function Fraction: Double;
    { 0..1 position of a value along the control, and the value at such a position; linear
      here, the knob can make them logarithmic }
    function FractionOf(AValue: Double): Double; virtual;
    function ValueAt(AFraction: Double): Double; virtual;
    function ValueText: string;
    procedure DragTo(X, Y: Integer; Fine: Boolean); virtual; abstract;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure DblClick; override;
    property DragStartPos: Double read FDragStart;
    property DragX: Integer read FDragX;
    property DragY: Integer read FDragY;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property Min: Double read FMin write SetMin;
    property Max: Double read FMax write SetMax;
    property Position: Double read FPos write SetPos;
    property DefaultPosition: Double read FDefault write FDefault;
    { > 0: Position snaps to multiples of Step (a TTrackBar-style integer control) }
    property Step: Double read FStep write FStep;
    property Decimals: Integer read FDecimals write SetDecimals default 1;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  TGLKnob = class(TGLValueWidget)
  private
    FLog: Boolean;
    procedure SetLog(AValue: Boolean);
    function IsLog: Boolean;
  protected
    procedure PaintGL; override;
    procedure DragTo(X, Y: Integer; Fine: Boolean); override;
    function FractionOf(AValue: Double): Double; override;
    function ValueAt(AFraction: Double): Double; override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    { the turn is proportional to the logarithm of the value (frequencies, times); needs Min > 0 }
    property Logarithmic: Boolean read FLog write SetLog default False;
  end;

  TGLSlider = class(TGLValueWidget)
  private
    FVertical: Boolean;
    procedure SetVertical(AValue: Boolean);
    function TrackRect: TRect;
  protected
    procedure PaintGL; override;
    procedure DragTo(X, Y: Integer; Fine: Boolean); override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property Vertical: Boolean read FVertical write SetVertical default False;
  end;

  { vertical graphic-EQ band slider: a dark, cool-toned face ruled with a horizontal line every
    dB (every 3 and 6 dB stronger, 0 dB brightest) like the mixer strips, a groove filled from the 0 dB line out to the
    knob, and the shadowed 3D knob. Put them side by side with no gap so the lines run through. }
  TGLEqSlider = class(TGLSlider)
  protected
    procedure PaintGL; override;
  public
    constructor Create(AOwner: TComponent); override;
  end;

  { static text; follows the control Font (colour included) and the active style }
  TGLLabel = class(TGLWidget)
  private
    FAlignment: TAlignment;
    FLayout: TTextLayout;
    FWordWrap: Boolean;
    FTransparent: Boolean;
    FSunken: Boolean;
    procedure SetSunken(AValue: Boolean);
    procedure SetAlignment(AValue: TAlignment);
    procedure SetLayout(AValue: TTextLayout);
    procedure SetWordWrap(AValue: Boolean);
  protected
    procedure PaintGL; override;
    procedure CaptionChanged; override;
    function CanAutoSize(var NewWidth, NewHeight: Integer): Boolean; override;
    procedure CMFontChanged(var Msg: TMessage); message CM_FONTCHANGED;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property Alignment: TAlignment read FAlignment write SetAlignment default taLeftJustify;
    property Layout: TTextLayout read FLayout write SetLayout default tlTop;
    { drawn in a lowered bevel box (a read-out window); the text is kept clear of its edge }
    property Sunken: Boolean read FSunken write SetSunken default False;
    property WordWrap: Boolean read FWordWrap write SetWordWrap default False;
    property AutoSize default True;
    { accepted for form-file compatibility with TLabel; the label always shows the form through }
    property Transparent: Boolean read FTransparent write FTransparent default True;
    property Font;
    property ParentFont;
    property Visible;
  end;

  { titled frame that holds other controls (a TGroupBox that draws on GL) }
  TGLGroup = class(TGLWidget)
  protected
    procedure PaintGL; override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property Font;
    property ParentFont;
  end;

  { container that draws on GL (a TPanel): optional caption, own colour, edge lines }
  TGLPanel = class(TGLWidget)
  private
    FBevelOuter: TPanelBevel;
    FBevelKind: TBevelKind;
    FBevelEdges: TBevelEdges;
    FShowCaption: Boolean;
    FParentBackground: Boolean;
    FOnResize: TNotifyEvent;
    procedure SetBevelOuter(AValue: TPanelBevel);
    procedure SetBevelKind(AValue: TBevelKind);
    procedure SetBevelEdges(AValue: TBevelEdges);
    procedure SetShowCaption(AValue: Boolean);
  protected
    procedure PaintGL; override;
    procedure Resize; override;
    procedure CaptionChanged; override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property BevelOuter: TPanelBevel read FBevelOuter write SetBevelOuter default bvRaised;
    property BevelKind: TBevelKind read FBevelKind write SetBevelKind default bkNone;
    property BevelEdges: TBevelEdges read FBevelEdges write SetBevelEdges default [beLeft, beTop, beRight, beBottom];
    property ShowCaption: Boolean read FShowCaption write SetShowCaption default True;
    { accepted for form-file compatibility with TPanel }
    property ParentBackground: Boolean read FParentBackground write FParentBackground default True;
    property DoubleBuffered;
    property ParentDoubleBuffered;
    property Color;
    property Font;
    property ParentFont;
    property OnResize: TNotifyEvent read FOnResize write FOnResize;
  end;

  { A TGLPanel drawn as a recessed, rounded container - a lowered bevel box in one flat body colour
    with an inset shadow, like the frame-rate read-out. The controls on it paint over that same
    colour (transparent icon bars and labels included). }
  TGLRecessPanel = class(TGLPanel, IGLBackdrop)
  protected
    procedure PaintGL; override;
  public
    function GLBackdropColor(const ARect: TRect): TColor;
  end;

  TGLCollapseMode = (cmStrip, cmBar);

  { A TGLPanel drawn as a rounded container with a title-bar segment holding the Title and a
    collapse arrow at its top right. Collapsed, it shrinks to a slim vertical strip (arrow
    pointing right, Title upright beneath it) that moves to 5 pixels right of the control on
    its left (the drum pads); expanding restores the size and position. The children are hidden
    while collapsed. Children are laid out below the title bar (Top >= 34). }
  TGLCollapsePanel = class(TGLPanel, IGLBackdrop)
  private
    FTitle: string;
    FCollapsed: Boolean;
    FExpLeft, FExpWidth, FExpHeight: Integer;
    FHidden: TList;
    FHoverHead: Boolean;
    FHeadColor: TColor;
    FMode: TGLCollapseMode;
    FHeadH: Integer;
    FCornerColor: TColor;
    FAutoPlace: Boolean;
    FOnToggle: TNotifyEvent;
    procedure SetCornerColor(AValue: TColor);
    procedure SetHeadHeight(AValue: Integer);
    procedure SetHeadColor(AValue: TColor);
    procedure SetTitle(const AValue: string);
    procedure SetCollapsed(AValue: Boolean);
    procedure ApplyCollapsed;
    procedure CMMouseLeave(var Msg: TMessage); message CM_MOUSELEAVE;
  protected
    procedure PaintGL; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure Loaded; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { IGLBackdrop: a transparent icon bar in the title bar shows the title-bar colour }
    function GLBackdropColor(const ARect: TRect): TColor;
    { the title-bar colour: the theme's own, or HeadColor }
    function HeadFillColor: TColor;
  published
    property Title: string read FTitle write SetTitle;
    { height of the title-bar segment; raise it for a title bar that holds taller controls }
    property HeadHeight: Integer read FHeadH write SetHeadHeight default 32;
    { the colour behind the rounded corners when the panel sits on something that paints its own
      background (a custom-drawn surface); clNone takes the colour of the parent control }
    property CornerColor: TColor read FCornerColor write SetCornerColor default clNone;
    property Collapsed: Boolean read FCollapsed write SetCollapsed default False;
    { colour of the title-bar segment; clNone takes the theme's own }
    property HeadColor: TColor read FHeadColor write SetHeadColor default clNone;
    { cmStrip shrinks to a vertical strip; cmBar keeps the width and shrinks to the title bar }
    property CollapseMode: TGLCollapseMode read FMode write FMode default cmStrip;
    { False: the owner positions the panel; collapsing then only changes its size }
    property AutoPlace: Boolean read FAutoPlace write FAutoPlace default True;
    property OnToggle: TNotifyEvent read FOnToggle write FOnToggle;
  end;

  { single-selection list with its own scroll bar }
  TGLList = class(TGLWidget)
  private
    FItems: TStrings;
    FIndex: Integer;
    FTop: Integer;
    FItemHeight: Integer;
    FMultiSelect: Boolean;
    FPicked: TArray<Boolean>;
    FDragging: Boolean;
    FGrab: Integer;
    FLeft: Integer;              // horizontal scroll offset, pixels
    FContentW: Integer;          // widest item, pixels; -1 = measure on the next paint
    FHDragging: Boolean;
    FHGrab: Integer;
    FAnim: TTimer;               // glides the selection pill and the hover glow, like the menus
    FPillRow, FPillAlpha: Double;
    FHovRow, FHovAlpha: Double;
    FHoverIdx: Integer;
    FPhase: Double;
    procedure AnimTick(Sender: TObject);
    procedure Kick;
    procedure CMMouseLeave(var Msg: TMessage); message CM_MOUSELEAVE;
    procedure SetItems(AValue: TStrings);
    procedure SetIndex(AValue: Integer);
    procedure SetTop(AValue: Integer);
    procedure SetLeft(AValue: Integer);
    function NeedHBar: Boolean;
    function HBarH: Integer;
    function MaxLeft: Integer;
    function HThumbRect: TRect;
    function GetCount: Integer;
    function GetSelected(AIndex: Integer): Boolean;
    procedure SetSelected(AIndex: Integer; AValue: Boolean);
    function BodyH: Integer;
    function RowH: Integer;
    function VisibleRows: Integer;
    function MaxTop: Integer;
    function NeedBar: Boolean;
    function ThumbRect: TRect;
    procedure ItemsChanged(Sender: TObject);
    procedure WMGetDlgCode(var Msg: TWMGetDlgCode); message WM_GETDLGCODE;
  protected
    procedure PaintGL; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure Resize; override;
    procedure Loaded; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    property Count: Integer read GetCount;
    { MultiSelect: each row can be ticked on / off independently }
    property Selected[AIndex: Integer]: Boolean read GetSelected write SetSelected;
  published
    property Items: TStrings read FItems write SetItems;
    property MultiSelect: Boolean read FMultiSelect write FMultiSelect default False;
    property ItemIndex: Integer read FIndex write SetIndex default -1;
    { rows are at least tall enough for the font }
    property ItemHeight: Integer read FItemHeight write FItemHeight default 20;
    property TabStop default True;
    property Font;
    property ParentFont;
  end;

  TGLMemoRow = record
    Line, Start, Len: Integer;
  end;

  TGLTextPos = record
    Line, Col: Integer;
  end;

  { read-only multi-line text viewer: scroll bars, word wrap, mouse / keyboard
    selection and copy. (Every memo in UDAW is a display, never an editor.) }
  TGLMemo = class(TGLWidget)
  private
    FLines: TStrings;
    FReadOnly: Boolean;
    FPlainText: Boolean;
    FScrollBars: System.UITypes.TScrollStyle;
    FWordWrap: Boolean;
    FRows: TArray<TGLMemoRow>;
    FRowsValid: Boolean;
    FLayoutW: Integer;
    FMaxPx: Integer;
    FTopRow, FLeftPx: Integer;
    FSelA, FSelC: TGLTextPos;
    FDragV, FDragH, FSelecting: Boolean;
    FGrab: Integer;
    FMeasure: TBitmap;
    FMaxLength: Integer;
    FOnChange: TNotifyEvent;
    FCaretOn: Boolean;
    FTimer: TTimer;
    FInChange: Boolean;
    FPrefX: Integer;
    FUndoText: TArray<string>;
    FUndoSel: TArray<Integer>;
    procedure Blink(Sender: TObject);
    procedure PushUndo;
    procedure DoUndo;
    procedure ReplaceSel(const S: string);
    procedure EditKey(var Key: Word; Shift: TShiftState);
    procedure MoveCaret(const P: TGLTextPos; AExtend: Boolean);
    function CaretRow: Integer;
    function ColAtRowX(ARow, AX: Integer): Integer;
    function CaretPixelX: Integer;
    procedure EnsureCaretVisible;
    function PosToOffset(const P: TGLTextPos): Integer;
    function OffsetToPos(AOffset: Integer): TGLTextPos;
    function GetSelStart: Integer;
    procedure SetSelStart(AValue: Integer);
    function GetSelLength: Integer;
    procedure SetSelLength(AValue: Integer);
    function GetSelText: string;
    procedure SetSelText(const AValue: string);
    procedure WMSetFocus(var Msg: TWMSetFocus); message WM_SETFOCUS;
    procedure WMKillFocus(var Msg: TWMKillFocus); message WM_KILLFOCUS;
    procedure SetLines(AValue: TStrings);
    procedure SetScrollBars(AValue: System.UITypes.TScrollStyle);
    procedure SetWordWrap(AValue: Boolean);
    function GetText: string;
    procedure SetText(const AValue: string);
    procedure LinesChanged(Sender: TObject);
    procedure PrepMeasure;
    function LineH: Integer;
    function ShowV: Boolean;
    function ShowH: Boolean;
    function ViewW: Integer;
    function ViewH: Integer;
    procedure EnsureLayout;
    procedure WrapLine(ALine, AWidth: Integer; var ARows: TArray<TGLMemoRow>; var ACount: Integer);
    function MaxTopRow: Integer;
    function MaxLeftPx: Integer;
    procedure ClampScroll;
    function RowText(const R: TGLMemoRow): string;
    function PosAt(X, Y: Integer): TGLTextPos;
    function HasSel: Boolean;
    function SelectedText: string;
    function PosLess(const A, B: TGLTextPos): Boolean;
    function VThumb: TRect;
    function HThumb: TRect;
    procedure WMGetDlgCode(var Msg: TWMGetDlgCode); message WM_GETDLGCODE;
  protected
    procedure PaintGL; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure KeyPress(var Key: Char); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Clear;
    procedure CutToClipboard;
    procedure PasteFromClipboard;
    property SelStart: Integer read GetSelStart write SetSelStart;
    property SelLength: Integer read GetSelLength write SetSelLength;
    property SelText: string read GetSelText write SetSelText;
    procedure SelectAll;
    procedure CopyToClipboard;
    procedure ScrollToEnd;
    property Text: string read GetText write SetText;
  published
    property Lines: TStrings read FLines write SetLines;
    { accepted for form-file compatibility with TMemo; the viewer never edits }
    property ReadOnly: Boolean read FReadOnly write FReadOnly default True;
    property MaxLength: Integer read FMaxLength write FMaxLength default 0;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    property PlainText: Boolean read FPlainText write FPlainText default True;
    property ScrollBars: System.UITypes.TScrollStyle read FScrollBars write SetScrollBars default System.UITypes.TScrollStyle.ssNone;
    property WordWrap: Boolean read FWordWrap write SetWordWrap default True;
    property TabStop default True;
    property Font;
    property ParentFont;
  end;

  TGLColumn = class(TCollectionItem)
  private
    FCaption: string;
    FWidth: Integer;
    FAlignment: TAlignment;
    procedure SetCaption(const AValue: string);
    procedure SetWidth(AValue: Integer);
    procedure SetAlignment(AValue: TAlignment);
  public
    constructor Create(ACollection: TCollection); override;
    procedure Assign(ASource: TPersistent); override;
  published
    property Caption: string read FCaption write SetCaption;
    property Width: Integer read FWidth write SetWidth default 100;
    property Alignment: TAlignment read FAlignment write SetAlignment default taLeftJustify;
  end;

  TGLListView = class;

  TGLListItem = class
  private
    FOwner: TGLListView;
    FCaption: string;
    FSubItems: TStringList;
    FData: Pointer;
    procedure SetCaption(const AValue: string);
    procedure SubChanged(Sender: TObject);
    function GetIndex: Integer;
  public
    constructor Create(AOwner: TGLListView);
    destructor Destroy; override;
    property Caption: string read FCaption write SetCaption;
    property SubItems: TStringList read FSubItems;
    property Data: Pointer read FData write FData;
    property Index: Integer read GetIndex;
  end;

  TGLListItems = class
  private
    FOwner: TGLListView;
    FList: TList;
    FUpdating: Integer;
    function GetCount: Integer;
    function GetItem(AIndex: Integer): TGLListItem;
  public
    constructor Create(AOwner: TGLListView);
    destructor Destroy; override;
    function Add: TGLListItem;
    procedure Clear;
    procedure BeginUpdate;
    procedure EndUpdate;
    property Count: Integer read GetCount;
    property Items[AIndex: Integer]: TGLListItem read GetItem; default;
  end;

  { report-style list (columns + rows) with its own scroll bar }
  TGLListView = class(TGLWidget)
  private
    FColumns: TCollection;
    FItems: TGLListItems;
    FIndex: Integer;
    FTop: Integer;
    FGridLines: Boolean;
    FReadOnly: Boolean;
    FRowSelect: Boolean;
    FViewStyle: TViewStyle;
    FMultiSelect: Boolean;
    FSel: TArray<Boolean>;
    FAnchor: Integer;
    FDragging: Boolean;
    FGrab: Integer;
    FAnim: TTimer;                  // glides the highlight pill, like the menus do
    FPillRow, FPillAlpha: Double;
    FHovRow, FHovAlpha: Double;
    FHoverIdx: Integer;
    FPhase: Double;
    function BodyH: Integer;
    procedure AnimTick(Sender: TObject);
    procedure Kick;
    procedure CMMouseLeave(var Msg: TMessage); message CM_MOUSELEAVE;
    procedure SetColumns(AValue: TCollection);
    procedure SetIndex(AValue: Integer);
    procedure SetTop(AValue: Integer);
    procedure SetGridLines(AValue: Boolean);
    function GetSelected: TGLListItem;
    function RowH: Integer;
    function HeaderH: Integer;
    function VisibleRows: Integer;
    function MaxTop: Integer;
    function NeedBar: Boolean;
    function ThumbRect: TRect;
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
    procedure ItemsChanged;
    property Items: TGLListItems read FItems;
    property Selected: TGLListItem read GetSelected;
    { MultiSelect: Ctrl+click toggles a row, Shift+click selects a range }
    function IsSelected(AIndex: Integer): Boolean;
    function SelCount: Integer;
    { the row under a point in the control's own coordinates, -1 on the header, a scroll bar or empty space }
    function ItemAt(X, Y: Integer): Integer;
    property ItemIndex: Integer read FIndex write SetIndex;
  published
    property Columns: TCollection read FColumns write SetColumns;
    property GridLines: Boolean read FGridLines write SetGridLines default False;
    { accepted for form-file compatibility with TListView }
    property ReadOnly: Boolean read FReadOnly write FReadOnly default False;
    property RowSelect: Boolean read FRowSelect write FRowSelect default False;
    property MultiSelect: Boolean read FMultiSelect write FMultiSelect default False;
    property ViewStyle: TViewStyle read FViewStyle write FViewStyle default vsIcon;
    property TabStop default True;
    property Font;
    property ParentFont;
  end;

  TGLPageControl = class;

  { one page of a TGLPageControl (a TTabSheet that draws on GL) }
  TGLPage = class(TGLWidget)
  private
    FImageIndex: Integer;
    FTabVisible: Boolean;
    { designed child bounds, re-applied once the page gets its real size (see
      AlignControls) so right/bottom anchors are measured from the right baseline }
    FDesignBounds: TArray<TRect>;
    FRebased: Boolean;
    FRebasing: Boolean;
    function GetPageControl: TGLPageControl;
    function GetPageIndex: Integer;
    procedure SetTabVisible(AValue: Boolean);
  protected
    procedure PaintGL; override;
    procedure SetParent(AParent: TWinControl); override;
    procedure Loaded; override;
    procedure AlignControls(AControl: TControl; var ARect: TRect); override;
    procedure CaptionChanged; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    property PageControl: TGLPageControl read GetPageControl;
    property PageIndex: Integer read GetPageIndex;
  published
    { accepted for form-file compatibility with TTabSheet }
    property ImageIndex: Integer read FImageIndex write FImageIndex default -1;
    property TabVisible: Boolean read FTabVisible write SetTabVisible default True;
    property DoubleBuffered;
    property ParentDoubleBuffered;
  end;

  { the tab strip of a TGLPageControl: a small shared-surface view across the top }
  TGLTabHeader = class(TGLWidget)
  private
    FOwnerPC: TGLPageControl;
    FHoverTab: Integer;
    FAnim: TTimer;                      // glides the active-tab pill, like the menus' highlight
    FPillL, FPillR: Double;             // where the pill is drawn
    FGoalL, FGoalR: Integer;            // where it is heading
    FPillInit: Boolean;
    FPhase: Double;                     // drives the sweep of light across the pill
    procedure AnimTick(Sender: TObject);
    procedure CMMouseLeave(var Msg: TMessage); message CM_MOUSELEAVE;
  protected
    procedure PaintGL; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    constructor CreateFor(AOwner: TGLPageControl);
  end;

  { pages with a tab strip: the GL counterpart of TPageControl. Like TPageControl,
    OnChange is raised only when the user changes the page, not when code sets
    ActivePage. }
  TGLPageControl = class(TCustomControl)
  private
    FPages: TList;
    FActive: TGLPage;
    FHeader: TGLTabHeader;
    FMultiLine: Boolean;
    FTabsVisible: Boolean;
    FOnChange: TNotifyEvent;
    FTabRects: TArray<TRect>;
    FTabPages: TArray<TGLPage>;
    FLayoutW: Integer;
    FLayoutValid: Boolean;
    FMeasure: TBitmap;
    FTabOver: Boolean;
    FTabScroll: Integer;
    FTabMax: Integer;
    procedure ScrollTabs(ADelta: Integer);
    procedure RevealActiveTab;
    procedure SetActivePage(AValue: TGLPage);
    function GetActivePageIndex: Integer;
    procedure SetActivePageIndex(AValue: Integer);
    procedure SetMultiLine(AValue: Boolean);
    procedure SetTabsVisible(AValue: Boolean);
    function GetPageCount: Integer;
    function GetPage(AIndex: Integer): TGLPage;
    procedure Relayout;
    procedure EnsureLayout;
    procedure UserSelect(APage: TGLPage);
    procedure WMEraseBkgnd(var Msg: TWMEraseBkgnd); message WM_ERASEBKGND;
    procedure WMGetDlgCode(var Msg: TWMGetDlgCode); message WM_GETDLGCODE;
    procedure WMSetFocus(var Msg: TWMSetFocus); message WM_SETFOCUS;
    procedure WMKillFocus(var Msg: TWMKillFocus); message WM_KILLFOCUS;
    procedure CMFontChanged(var Msg: TMessage); message CM_FONTCHANGED;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure Loaded; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure AddPage(APage: TGLPage);
    procedure RemovePage(APage: TGLPage);
    procedure PageChanged;
    procedure SelectNextPage(AGoForward: Boolean);
    { where the last visible tab is, in this control's coordinates (a 0-width rect at the left when there is none): lets a control sit in the header row just after the tabs }
    function LastTabRect: TRect;
    property PageCount: Integer read GetPageCount;
    property Pages[AIndex: Integer]: TGLPage read GetPage;
    property ActivePageIndex: Integer read GetActivePageIndex write SetActivePageIndex;
  published
    property ActivePage: TGLPage read FActive write SetActivePage;
    property MultiLine: Boolean read FMultiLine write SetMultiLine default False;
    { False: the tab header is not shown - another control (a mode bar) picks the page }
    property TabsVisible: Boolean read FTabsVisible write SetTabsVisible default True;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    property Align;
    property Anchors;
    property Enabled;
    property Font;
    property ParentFont;
    property PopupMenu;
    property TabOrder;
    property TabStop default True;
    property Visible;
    property OnEnter;
    property OnExit;
    property OnResize;
  end;

  { draggable divider between two aligned panes (a TSplitter on GL): it resizes the
    control that sits against it on the side opposite its Align }
  TGLSplitter = class(TGLWidget)
  private
    FMinSize: Integer;
    FResizeStyle: TResizeStyle;
    FDragging: Boolean;
    FDownAt: Integer;
    FNeighbor: TControl;
    FStartSize: Integer;
    FOnMoved: TNotifyEvent;
    function FindNeighbor: TControl;
    function IsHorizontalBar: Boolean;
  protected
    procedure PaintGL; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property MinSize: Integer read FMinSize write FMinSize default 30;
    { fires when a drag ends: the pane beside the splitter has its new size }
    property OnMoved: TNotifyEvent read FOnMoved write FOnMoved;
    { accepted for form-file compatibility with TSplitter; the pane always follows the pointer }
    property ResizeStyle: TResizeStyle read FResizeStyle write FResizeStyle default rsPattern;
  end;

  TGLScrollBox = class;

  { Position / Range of one axis of a TGLScrollBox (the TScrollBox.VertScrollBar API) }
  TGLScrollAxis = class(TPersistent)
  private
    FBox: TGLScrollBox;
    FVertical: Boolean;
    function GetPosition: Integer;
    procedure SetPosition(AValue: Integer);
    function GetRange: Integer;
  public
    constructor Create(ABox: TGLScrollBox; AVertical: Boolean);
    property Position: Integer read GetPosition write SetPosition;
    property Range: Integer read GetRange;
  end;

  { container whose children scroll vertically when they do not fit }
  TGLScrollBox = class(TGLWidget)
  private
    FPosY, FPosX: Integer;
    FPad, FBottomPad: Integer;
    FVert, FHorz: TGLScrollAxis;
    FDragging, FDraggingX: Boolean;
    FGrab: Integer;
    function ContentHeight: Integer;
    function ContentWidth: Integer;
    function MaxPos: Integer;
    function MaxPosX: Integer;
    function NeedBar: Boolean;
    function NeedBarX: Boolean;
    function ThumbRect: TRect;
    function ThumbRectX: TRect;
  protected
    procedure PaintGL; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetScroll(AValue: Integer);
    procedure SetScrollX(AValue: Integer);
    property VertScrollBar: TGLScrollAxis read FVert;
    property HorzScrollBar: TGLScrollAxis read FHorz;
  published
    property OnResize;
    { space kept past the last child before a scroll bar is needed }
    property ContentPadding: Integer read FPad write FPad default 8;
    { extra scroll room below the last child (vertical only), so a drop-down at the bottom can open in full }
    property BottomPadding: Integer read FBottomPad write FBottomPad default 0;
  end;

  TGLStatusPanel = class(TCollectionItem)
  private
    FText: string;
    FWidth: Integer;
    procedure SetText(const AValue: string);
    procedure SetWidth(AValue: Integer);
  public
    constructor Create(ACollection: TCollection); override;
  published
    property Text: string read FText write SetText;
    property Width: Integer read FWidth write SetWidth default 100;
  end;

  { status strip: one line of text (SimpleText) or a row of panels }
  TGLStatusBar = class(TGLWidget)
  private
    FSimpleText: string;
    FSimplePanel: Boolean;
    FPanels: TCollection;
    procedure SetSimpleText(const AValue: string);
    procedure SetSimplePanel(AValue: Boolean);
    procedure SetPanels(AValue: TCollection);
  protected
    procedure PaintGL; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  published
    property SimpleText: string read FSimpleText write SetSimpleText;
    property SimplePanel: Boolean read FSimplePanel write SetSimplePanel default False;
    property Panels: TCollection read FPanels write SetPanels;
  end;

  TGLTree = class;
  TGLTreeNodes = class;

  TGLTreeNode = class
  private
    FOwner: TGLTree;
    FParent: TGLTreeNode;
    FKids: TList;
    FText: string;
    FData: Pointer;
    FExpanded: Boolean;
    function GetCount: Integer;
    function GetItem(AIndex: Integer): TGLTreeNode;
    function GetSelected: Boolean;
    procedure SetSelected(AValue: Boolean);
    procedure SetText(const AValue: string);
    function GetLevel: Integer;
  public
    constructor Create(AOwner: TGLTree; AParent: TGLTreeNode);
    destructor Destroy; override;
    procedure Delete;
    procedure DeleteChildren;
    procedure Expand(ARecurse: Boolean = False);
    procedure Collapse;
    property Text: string read FText write SetText;
    property Data: Pointer read FData write FData;
    property Parent: TGLTreeNode read FParent;
    property Count: Integer read GetCount;
    property Item[AIndex: Integer]: TGLTreeNode read GetItem;
    property Expanded: Boolean read FExpanded;
    property Selected: Boolean read GetSelected write SetSelected;
    property Level: Integer read GetLevel;
  end;

  TGLTreeExpandingEvent = procedure(Sender: TObject; Node: TGLTreeNode; var AllowExpansion: Boolean) of object;

  { all the nodes of a tree; Items[i] runs over every node in display order }
  TGLTreeNodes = class
  private
    FOwner: TGLTree;
    FRoots: TList;
    FFlat: TList;
    FFlatValid: Boolean;
    FUpdating: Integer;
    procedure BuildFlat;
    function GetCount: Integer;
    function GetItem(AIndex: Integer): TGLTreeNode;
  public
    constructor Create(AOwner: TGLTree);
    destructor Destroy; override;
    function AddChild(AParent: TGLTreeNode; const AText: string): TGLTreeNode;
    procedure Clear;
    procedure BeginUpdate;
    procedure EndUpdate;
    procedure Changed;
    property Count: Integer read GetCount;
    property Items[AIndex: Integer]: TGLTreeNode read GetItem; default;
  end;

  { expandable tree with its own scroll bar (a TTreeView on GL) }
  TGLTree = class(TGLWidget)
  private
    FNodes: TGLTreeNodes;
    FSelected: TGLTreeNode;
    FIndent: Integer;
    FTop: Integer;
    FRows: TArray<TGLTreeNode>;
    FRowsValid: Boolean;
    FDragging: Boolean;
    FGrab: Integer;
    FLeft: Integer;              // horizontal scroll offset, pixels
    FContentW: Integer;          // widest row, pixels; -1 = measure on the next paint
    FHDragging: Boolean;
    FHGrab: Integer;
    FOnExpanding: TGLTreeExpandingEvent;
    FAnim: TTimer;               // glides the selection pill and the hover glow, like the menus
    FPillRow, FPillAlpha: Double;
    FHovRow, FHovAlpha: Double;
    FHoverIdx: Integer;
    FPhase: Double;
    procedure AnimTick(Sender: TObject);
    procedure Kick;
    function SelRow: Integer;
    procedure CMMouseLeave(var Msg: TMessage); message CM_MOUSELEAVE;
    procedure BuildRows;
    function BodyH: Integer;
    function RowH: Integer;
    function VisibleRows: Integer;
    function MaxTop: Integer;
    function NeedBar: Boolean;
    function ThumbRect: TRect;
    function NeedHBar: Boolean;
    function HBarH: Integer;
    function MaxLeft: Integer;
    function HThumbRect: TRect;
    procedure SetLeft(AValue: Integer);
    procedure SetTop(AValue: Integer);
    procedure SetSelectedNode(AValue: TGLTreeNode);
    procedure WMGetDlgCode(var Msg: TWMGetDlgCode); message WM_GETDLGCODE;
    procedure CMVisibleChanged(var Msg: TMessage); message CM_VISIBLECHANGED;
    procedure CMFontChanged(var Msg: TMessage); message CM_FONTCHANGED;
    procedure NodeRemoved(ANode: TGLTreeNode);
  protected
    procedure PaintGL; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure DblClick; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function GetNodeAt(X, Y: Integer): TGLTreeNode;
    procedure NodesChanged;
    property Items: TGLTreeNodes read FNodes;
    property Selected: TGLTreeNode read FSelected write SetSelectedNode;
  published
    property Indent: Integer read FIndent write FIndent default 19;
    property TabStop default True;
    property Font;
    property ParentFont;
    property OnExpanding: TGLTreeExpandingEvent read FOnExpanding write FOnExpanding;
  end;

  { divider line or frame (a TBevel on GL) }
  TGLBevel = class(TGLWidget)
  private
    FShape: TBevelShape;
    FStyle: TBevelStyle;
    procedure SetShape(AValue: TBevelShape);
    procedure SetStyle(AValue: TBevelStyle);
  protected
    procedure PaintGL; override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property Shape: TBevelShape read FShape write SetShape default bsBox;
    property Style: TBevelStyle read FStyle write SetStyle default bsLowered;
  end;

  { raised 3D rail with a slanted band of light that glides along it, over and over - the same
    glisten the menus and scroll-bar thumbs carry }
  TGLShineBar = class(TGLWidget)
  private
    FTimer: TTimer;
    FPhase: Double;
    procedure Tick(Sender: TObject);
  protected
    procedure PaintGL; override;
    procedure Loaded; override;
  public
    constructor Create(AOwner: TComponent); override;
  end;

  TGLProgress = class(TGLWidget)
  private
    FMin, FMax, FPos: Double;
    FVertical: Boolean;
    FSegmented: Boolean;
    procedure SetMin(AValue: Double);
    procedure SetMax(AValue: Double);
    procedure SetPos(AValue: Double);
    procedure SetVertical(AValue: Boolean);
    procedure SetSegmented(AValue: Boolean);
    procedure PaintSegments(cv: TGLCanvas; AFraction: Double);
  protected
    procedure PaintGL; override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    { a level meter: evenly sized segments, green then amber from 70 % and red from 90 % of the range }
    property Segmented: Boolean read FSegmented write SetSegmented default False;
    property Min: Double read FMin write SetMin;
    property Max: Double read FMax write SetMax;
    property Position: Double read FPos write SetPos;
    property Vertical: Boolean read FVertical write SetVertical default False;
  end;

  TGLTabStrip = class(TGLWidget)
  private
    FTabs: TStringList;
    FHintTexts: TStringList;
    FIndex, FHoverTab: Integer;
    FOnChange: TNotifyEvent;
    FMeasure: TBitmap;
    FWidths: TArray<Integer>;
    FLayoutW: Integer;
    FLayoutValid: Boolean;
    FOver: Boolean;
    FScroll, FMaxScroll: Integer;
    FAnim: TTimer;                      // glides the active-tab pill and sweeps light across it
    FPillL, FPillR: Double;
    FGoalL, FGoalR: Integer;
    FPillInit: Boolean;
    FPhase: Double;
    FCurved: Boolean;
    FTint: TColor;                      // clNone = the default dark green of the curved tabs
    procedure AnimTick(Sender: TObject);
    procedure EnsureLayout;
    procedure ScrollBy(ADelta: Integer);
    procedure RevealTab(AIndex: Integer);
    function GetTabs: string;
    procedure SetTabs(const AValue: string);
    function GetHints: string;
    procedure SetHints(const AValue: string);
    procedure SetIndex(AValue: Integer);
    function TabRect(AIndex: Integer): TRect;
    function TabAt(X, Y: Integer): Integer;
    procedure CMMouseLeave(var Msg: TMessage); message CM_MOUSELEAVE;
  protected
    procedure PaintGL; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  published
    property Tabs: string read GetTabs write SetTabs;
    property Hints: string read GetHints write SetHints;
    property TabIndex: Integer read FIndex write SetIndex default 0;
    { True: curved-top tabs with an animated dark green pill (the Timeline's tabs); False: flat tabs }
    property CurvedTabs: Boolean read FCurved write FCurved default False;
    { the colour of the curved tabs' lit pill (clNone: the default dark green) }
    property TabColor: TColor read FTint write FTint default clNone;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  { TTrackBar look-alike: a horizontal / vertical slider with integer Min / Max / Position }
  TGLTrackBar = class(TGLSlider)
  private
    FThumbLength: Integer;
    function GetIMin: Integer;
    procedure SetIMin(AValue: Integer);
    function GetIMax: Integer;
    procedure SetIMax(AValue: Integer);
    function GetIPos: Integer;
    procedure SetIPos(AValue: Integer);
  public
    constructor Create(AOwner: TComponent); override;
  published
    property Min: Integer read GetIMin write SetIMin;
    property Max: Integer read GetIMax write SetIMax;
    property Position: Integer read GetIPos write SetIPos;
    { accepted for form-file compatibility with TTrackBar }
    property ThumbLength: Integer read FThumbLength write FThumbLength default 20;
  end;

  { scroll bar with TScrollBar semantics: integer Min / Max / Position, and when
    PageSize > 0 the largest Position is Max - PageSize + 1 }
  TGLScrollBar = class(TGLWidget)
  private
    FMin, FMax, FPage, FPos: Integer;
    FSmall, FLarge: Integer;
    FVertical, FDragging: Boolean;
    FGrab: Integer;
    FOnChange: TNotifyEvent;
    procedure SetMin(AValue: Integer);
    procedure SetMax(AValue: Integer);
    procedure SetPage(AValue: Integer);
    procedure SetPos(AValue: Integer);
    procedure UserSetPos(AValue: Integer);
    procedure SetVertical(AValue: Boolean);
    function GetKind: TScrollBarKind;
    procedure SetKind(AValue: TScrollBarKind);
    function HiPos: Integer;
    function Span: Integer;
    function ThumbLen: Integer;
    function ThumbStart: Integer;
    function Along(X, Y: Integer): Integer;
  protected
    procedure PaintGL; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetParams(APosition, AMin, AMax: Integer);
  published
    property Min: Integer read FMin write SetMin default 0;
    property Max: Integer read FMax write SetMax default 100;
    property PageSize: Integer read FPage write SetPage default 0;
    property Position: Integer read FPos write SetPos default 0;
    property SmallChange: Integer read FSmall write FSmall default 1;
    property LargeChange: Integer read FLarge write FLarge default 1;
    property Kind: TScrollBarKind read GetKind write SetKind default sbHorizontal;
    property Vertical: Boolean read FVertical write SetVertical default False;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  TGLEdit = class(TGLWidget)
  private
    FText: string;
    FCaret, FAnchor: Integer;
    FScroll: Integer;
    FReadOnly: Boolean;
    FPasswordChar: Char;
    FMaxLength: Integer;
    FNumbersOnly: Boolean;
    FFlat: Boolean;
    FTextHint: string;
    FCaretOn: Boolean;
    FTimer: TTimer;
    FCharX: TArray<Integer>;
    FOnChange: TNotifyEvent;
    procedure SetText(const AValue: string);
    procedure SetCaret(AValue: Integer; AExtend: Boolean);
    procedure SetPasswordChar(AValue: Char);
    procedure Blink(Sender: TObject);
    function Shown: string;
    function IndexAtX(X: Integer): Integer;
    procedure InsertText(const S: string);
    procedure DeleteSelection;
    function HasSelection: Boolean;
    procedure Changed;
    procedure WMGetDlgCode(var Msg: TWMGetDlgCode); message WM_GETDLGCODE;
    procedure WMSetFocus(var Msg: TWMSetFocus); message WM_SETFOCUS;
    procedure WMKillFocus(var Msg: TWMKillFocus); message WM_KILLFOCUS;
  protected
    procedure PaintGL; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure KeyPress(var Key: Char); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SelectAll;
    { no rounded frame: the edit sits inside another control }
    property Flat: Boolean read FFlat write FFlat;
  published
    property Text: string read FText write SetText;
    property ReadOnly: Boolean read FReadOnly write FReadOnly default False;
    property PasswordChar: Char read FPasswordChar write SetPasswordChar default #0;
    property MaxLength: Integer read FMaxLength write FMaxLength default 0;
    property NumbersOnly: Boolean read FNumbersOnly write FNumbersOnly default False;
    { grey prompt shown while the box is empty and unfocused }
    property TextHint: string read FTextHint write FTextHint;
    property TabStop default True;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    property OnKeyDown;
    property OnKeyPress;
  end;

  TGLCombo = class;

  { the drop-down list: a borderless top-level GL window owned by the combo }
  TGLComboList = class(TGLView)
  private
    FCombo: TGLCombo;
    FHot: Integer;
    FTop: Integer;
    FGlowRow: Integer;     // the row the animated highlight is on
    FGlow: Double;         // 0..1 fade of that highlight
    FPhase: Double;        // drives the pulse and the sweeping band
    FAnim: TTimer;
    function RowAt(Y: Integer): Integer;
    procedure AnimTick(Sender: TObject);
    procedure DrawRowGlow(cv: TGLCanvas; const R: TRect; AAccent: TColor);
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure PaintGL; override;
    procedure PrepareCanvas(ACanvas: TGLCanvas); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure WMMouseActivate(var Msg: TWMMouseActivate); message WM_MOUSEACTIVATE;
    procedure CMRelease(var Msg: TMessage); message CM_RELEASE;
  public
    constructor CreateFor(ACombo: TGLCombo);
    { hides the list and frees it once the current message is done }
    procedure Dismiss;
  end;

  TGLCombo = class(TGLWidget)
  private
    FItems: TStrings;
    FIndex: Integer;
    FList: TGLComboList;
    FDropRows: Integer;
    FStyle: TComboBoxStyle;
    FEdit: TGLEdit;
    FSync: Boolean;
    FOnChange: TNotifyEvent;
    FOnSelect: TNotifyEvent;
    procedure SetStyle(AValue: TComboBoxStyle);
    procedure SetText(const AValue: string);
    procedure EditChanged(Sender: TObject);
    procedure SetItems(AValue: TStrings);
    procedure SetIndex(AValue: Integer);
    procedure UserSetIndex(AValue: Integer);
    function GetText: string;
    function GetListWindow: TWinControl;
  protected
    procedure PaintGL; override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure Loaded; override;
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure DropDown;
    procedure CloseUp;
    function DroppedDown: Boolean;
    procedure Pick(AIndex: Integer);
    property Text: string read GetText write SetText;
    { the open drop-down window, nil when closed }
    property ListWindow: TWinControl read GetListWindow;
  published
    property Items: TStrings read FItems write SetItems;
    { csDropDown: the text can be typed; csDropDownList (default here): pick only }
    property Style: TComboBoxStyle read FStyle write SetStyle default csDropDownList;
    property ItemIndex: Integer read FIndex write SetIndex default -1;
    property DropDownRows: Integer read FDropRows write FDropRows default 8;
    property TabStop default True;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    { an entry was chosen from the drop-down list (not raised while typing in the box) }
    property OnSelect: TNotifyEvent read FOnSelect write FOnSelect;
  end;

{ Draws a scroll-bar thumb as a raised, bevelled 3D piece. The thumb glides to wherever it belongs
  (across a horizontal bar, down a vertical one) instead of jumping, like the menus' highlight; while
  AActive (being dragged) it follows exactly. ASlot tells a view's two bars apart (0 = vertical,
  1 = horizontal); AGoal is where the thumb belongs. It lights up like a selected menu item, with a
  band of light sweeping along the bar, while dragged or while the pointer is over the bar. }
procedure GLDrawScrollThumb(cv: TGLCanvas; AView: TGLView; ASlot: Integer; const AGoal: TRect;
  AVertical, AActive, AHot: Boolean; AField, AInk, AAccent: TColor);

{ A raised, domed slider knob with a soft drop shadow beneath it. ABase is the knob's own colour;
  AHorizontalGrip draws the grip line across a vertical slider's cap (False: along it). }
procedure GLDrawSliderKnob(cv: TGLCanvas; const R: TRect; ABase: TColor; AHot, AGripAcross: Boolean);

{ Shadow depth, as on the buttons. DrawDropShadow: a soft shadow beneath R (it falls ADepth px below
  R, so leave that room under the body). DrawInsetShadow: shades a recessed area from the top and
  left inside R's edge. }
procedure DrawDropShadow(cv: TGLCanvas; const R: TRect; ARadius, ADepth: Integer;
  AStrength: Double = 1.0);
procedure DrawInsetShadow(cv: TGLCanvas; const R: TRect; ADepth: Integer);
{ a rounded three-dimensional box, raised or set into the surface; only the box itself is drawn, so
  the corners outside its curve keep whatever is behind it }
procedure DrawBox3D(cv: TGLCanvas; const R: TRect; AFace: TColor; ARaised: Boolean; ARadius: Integer);

{ Lines every single-line label up with the field it captions: a label that sits to the left of a
  combo box or edit box (within a short gap, and overlapping it vertically) is given that field's
  top and body height with its text centred, so the label and the field's own text share one
  baseline. Works through the whole control tree under AParent. }
procedure GLAlignLabelsToFields(AParent: TWinControl);

implementation


uses
  UDAW.DSP.MathTables, UDAW.UI.ThemeColors;

type
  TWinAccess = class(TWinControl);   // SelectNext is protected

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

{ the single flat colour inside a group box; the controls in it paint over the same colour }
function GroupBodyColor(AFace: TColor): TColor;
begin
  Result := Blend(AFace, clBlack, 0.14);
end;

{ Shadow depth for the controls, the same layered look as the buttons' drop shadow.
  DrawInsetShadow: a recessed control (field, list, tree, groove) is shaded from the top and the
  left inside its edge and catches a little light along the bottom and right.
  DrawDropShadow: a raised small control (check box, caption tab) casts a soft shadow below. }
procedure DrawInsetShadow(cv: TGLCanvas; const R: TRect; ADepth: Integer);
var
  i, x0, x1, y0, y1: Integer;
begin
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  for i := 0 to ADepth - 1 do
  begin
    cv.Brush.Color := clBlack;
    cv.Alpha := 0.34 * (1 - i / ADepth);
    x0 := R.Left + 4 + i;
    x1 := R.Right - 4 - i;
    y0 := R.Top + 4 + i;
    y1 := R.Bottom - 4 - i;
    if x1 > x0 then cv.FillRect(Rect(x0, R.Top + i, x1, R.Top + i + 1));
    if y1 > y0 then cv.FillRect(Rect(R.Left + i, y0, R.Left + i + 1, y1));
  end;
  cv.Brush.Color := clWhite;
  cv.Alpha := 0.09;
  x0 := R.Left + 5;
  x1 := R.Right - 5;
  y0 := R.Top + 5;
  y1 := R.Bottom - 5;
  if x1 > x0 then cv.FillRect(Rect(x0, R.Bottom - 1, x1, R.Bottom));
  if y1 > y0 then cv.FillRect(Rect(R.Right - 1, y0, R.Right, y1));
  cv.Alpha := 1;
end;

procedure DrawDropShadow(cv: TGLCanvas; const R: TRect; ARadius, ADepth: Integer;
  AStrength: Double = 1.0);
begin
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := clBlack;
  cv.Alpha := System.Math.Min(1.0, 0.24 * AStrength);
  cv.RoundRect(R.Left, R.Top + 1, R.Right, R.Bottom + ADepth, ARadius + 2, ARadius + 2);
  cv.Alpha := System.Math.Min(1.0, 0.32 * AStrength);
  cv.RoundRect(R.Left + 1, R.Top + 2, R.Right - 1, R.Bottom + ADepth - 1, ARadius + 1, ARadius + 1);
  cv.Alpha := System.Math.Min(1.0, 0.5 * AStrength);
  cv.RoundRect(R.Left + 1, R.Top + ADepth, R.Right - 1, R.Bottom + ADepth - 1, ARadius, ARadius);
  cv.Alpha := 1;
end;

{ The relief of a page tab (R is the tab body; its foot is square and open to the page below).
  DrawTabRaised: the selected tab - a gloss over its upper part, a shaded underside, a bright top
  lip, a lit left edge and a dark right edge; AShaded False leaves the body's own gloss alone.
  DrawTabShadow: the shadow the raised tab casts below its foot (needs 4 free rows under R).
  DrawTabSunken: an unselected tab, set into the surface - shaded from the top and the sides inside
  its edge, with a faint lit rim along its foot. }
procedure DrawTabRaised(cv: TGLCanvas; const R: TRect; AStrength: Double; AShaded: Boolean);
var
  h: Integer;
begin
  h := R.Bottom - R.Top;
  if h < 8 then Exit;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  if AShaded then
  begin
    cv.PushClip(Rect(R.Left, R.Top, R.Right, R.Bottom - 1));
    cv.Brush.Color := clWhite;
    cv.Alpha := 0.10 * AStrength;
    cv.RoundRect(R.Left + 2, R.Top + 1, R.Right - 2, R.Top + (h * 5) div 12, 9, 9);
    cv.Brush.Color := clBlack;
    cv.Alpha := 0.20 * AStrength;
    cv.RoundRect(R.Left + 1, R.Top + (h * 62) div 100, R.Right - 1, R.Bottom + 12, 11, 11);
    cv.PopClip;
  end;
  cv.Brush.Color := clWhite;
  cv.Alpha := 0.50 * AStrength;
  cv.FillRect(Rect(R.Left + 7, R.Top + 1, R.Right - 7, R.Top + 2));
  cv.Alpha := 0.22 * AStrength;
  cv.FillRect(Rect(R.Left + 1, R.Top + 8, R.Left + 2, R.Bottom - 1));
  cv.Brush.Color := clBlack;
  cv.Alpha := 0.38 * AStrength;
  cv.FillRect(Rect(R.Right - 2, R.Top + 8, R.Right - 1, R.Bottom - 1));
  cv.FillRect(Rect(R.Left + 1, R.Bottom - 2, R.Right - 1, R.Bottom - 1));
  cv.Alpha := 1;
end;

procedure DrawTabShadow(cv: TGLCanvas; const R: TRect; AStrength: Double);
var
  k: Integer;
begin
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := clBlack;
  for k := 0 to 3 do
  begin
    cv.Alpha := System.Math.Min(1.0, (0.40 - 0.09 * k) * AStrength);
    cv.FillRect(Rect(R.Left + 2 + k, R.Bottom + k, R.Right - 2 - k, R.Bottom + k + 1));
  end;
  cv.Alpha := 1;
end;

procedure DrawTabSunken(cv: TGLCanvas; const R: TRect; AStrength: Double; ABody: TColor = clNone);
var
  k, sl, el, rad: Integer;
  body0: TColor;
begin
  if R.Bottom - R.Top < 8 then Exit;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.PushClip(Rect(R.Left, R.Top, R.Right, R.Bottom - 1));
  if ABody = clNone then
  begin
    { square (flat) tabs: straight strips along the top and the sides }
    cv.Brush.Color := clBlack;
    cv.Alpha := 0.14 * AStrength;
    cv.RoundRect(R.Left, R.Top, R.Right, R.Bottom + 12, 11, 11);
    for k := 0 to 4 do
    begin
      cv.Alpha := 0.36 * (1 - k / 5) * AStrength;
      cv.FillRect(Rect(R.Left + 4 + k, R.Top + k, R.Right - 4 - k, R.Top + k + 1));
    end;
    for k := 0 to 2 do
    begin
      cv.Alpha := 0.28 * (1 - k / 3) * AStrength;
      cv.FillRect(Rect(R.Left + k, R.Top + 6, R.Left + k + 1, R.Bottom - 1));
      cv.FillRect(Rect(R.Right - k - 1, R.Top + 6, R.Right - k, R.Bottom - 1));
    end;
  end
  else
  begin
    { curved tabs: the shade is built from nested rounded outlines, so it follows the corner curves
      exactly - ring k is a dark rounded rectangle drawn k px inside the edge, then everything inside
      the next ring is put back to the body colour, leaving a 1 px band per ring. The top is shaded
      deeper (5 rings) than the sides (3 rings), as before. }
    body0 := Blend(ABody, clBlack, 0.14 * AStrength);
    cv.Alpha := 1;
    cv.Brush.Color := body0;
    cv.RoundRect(R.Left, R.Top, R.Right, R.Bottom + 12, 11, 11);
    for k := 0 to 4 do
    begin
      sl := System.Math.Min(k, 3);
      rad := System.Math.Max(3, 11 - 2 * k);
      cv.Brush.Color := clBlack;
      cv.Alpha := 0.36 * (1 - k / 5) * AStrength;
      cv.RoundRect(R.Left + sl, R.Top + k, R.Right - sl, R.Bottom + 12, rad, rad);
      sl := System.Math.Min(k + 1, 3);
      el := System.Math.Max(3, 11 - 2 * (k + 1));
      cv.Alpha := 1;
      cv.Brush.Color := body0;
      cv.RoundRect(R.Left + sl, R.Top + k + 1, R.Right - sl, R.Bottom + 12, el, el);
    end;
  end;
  cv.PopClip;
  cv.Brush.Color := clWhite;
  cv.Alpha := 0.10 * AStrength;
  cv.FillRect(Rect(R.Left + 2, R.Bottom - 2, R.Right - 2, R.Bottom - 1));
  cv.Alpha := 1;
end;


{ A rounded, three-dimensional box: a dark rim, a body a shade lighter (raised) or darker
  (lowered, set into the surface), a glossy band across the top and a soft shade along the
  bottom, and a fine specular line inside the rim - on the lit side. Used by the bevel boxes,
  the panels with a bevel and the group boxes. ARadius is capped to half the shorter side. }
procedure DrawBox3D(cv: TGLCanvas; const R: TRect; AFace: TColor; ARaised: Boolean; ARadius: Integer);
var
  rad, w, h: Integer;
  rim, body, spec: TColor;
begin
  w := R.Right - R.Left;
  h := R.Bottom - R.Top;
  if (w < 4) or (h < 4) then
  begin
    cv.Brush.Style := bsSolid;
    cv.Pen.Style := psClear;
    cv.Brush.Color := AFace;
    cv.FillRect(R);
    Exit;
  end;
  rad := Min(ARadius, Min(w, h) div 2);
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  rim := Blend(AFace, clBlack, 0.26);
  if ARaised then
  begin
    body := Blend(AFace, clWhite, 0.06);
    spec := Blend(AFace, clWhite, 0.55);
  end
  else
  begin
    body := Blend(AFace, clBlack, 0.14);
    spec := Blend(AFace, clWhite, 0.32);
  end;
  { rim, then the body inside it }
  cv.Brush.Color := rim;
  cv.RoundRect(R.Left, R.Top, R.Right, R.Bottom, rad * 2, rad * 2);
  cv.Brush.Color := body;
  cv.RoundRect(R.Left + 1, R.Top + 1, R.Right - 1, R.Bottom - 1, Max(2, rad * 2 - 2), Max(2, rad * 2 - 2));
  if ARaised then
  begin
    { gloss across the top; no dark band along the bottom }
    cv.Brush.Color := clWhite;
    cv.Alpha := 0.10;
    cv.RoundRect(R.Left + 2, R.Top + 2, R.Right - 2, R.Top + 2 + (h * 45) div 100, Max(2, rad * 2 - 4), Max(2, rad * 2 - 4));
  end
  else
  begin
    { set into the surface: a shadow cast from the top; nothing tinting the bottom }
    cv.Brush.Color := clBlack;
    cv.Alpha := 0.16;
    cv.RoundRect(R.Left + 2, R.Top + 2, R.Right - 2, R.Top + 2 + (h * 40) div 100, Max(2, rad * 2 - 4), Max(2, rad * 2 - 4));
  end;
  cv.Alpha := 1;
  if ARaised then
  begin
    { raised: the underside falls into shadow }
    cv.Brush.Color := clBlack;
    cv.Alpha := 0.16;
    cv.RoundRect(R.Left + 2, R.Bottom - 1 - Max(3, h div 6), R.Right - 2, R.Bottom - 1, Max(2, rad * 2 - 4), Max(2, rad * 2 - 4));
    cv.Alpha := 1;
  end
  else DrawInsetShadow(cv, Rect(R.Left + 1, R.Top + 1, R.Right - 1, R.Bottom - 1), 4);
  { the specular line just inside the rim }
  cv.Pen.Style := psSolid;
  cv.Pen.Color := spec;
  cv.Alpha := 0.55;
  cv.Brush.Style := bsClear;
  cv.RoundRect(R.Left + 1, R.Top + 1, R.Right - 1, R.Bottom - 1, Max(2, rad * 2 - 2), Max(2, rad * 2 - 2));
  cv.Alpha := 1;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
end;

{ TGLWidget }

constructor TGLWidget.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  SharedSurface := True;
  ControlStyle := ControlStyle + [csOpaque];
  ShowHint := True;
end;

function TGLWidget.GetHint: string;
begin
  Result := inherited Hint;
end;

procedure TGLWidget.SetHint(const AValue: string);
begin
  inherited Hint := AValue;
end;

procedure TGLWidget.SetCaption(const AValue: string);
begin
  if FCaption = AValue then Exit;
  FCaption := AValue;
  CaptionChanged;
  Invalidate;
end;

procedure TGLWidget.CaptionChanged;
begin
end;

procedure TGLWidget.CMMouseEnter(var Msg: TMessage);
begin
  inherited;
  FHover := True;
  if WantsGlow and (FGlowTimer = nil) then
  begin
    FGlowTimer := TTimer.Create(Self);
    FGlowTimer.Enabled := False;
    FGlowTimer.Interval := 15;
    FGlowTimer.OnTimer := GlowTick;
  end;
  if FGlowTimer <> nil then FGlowTimer.Enabled := True;
  Invalidate;
end;

function TGLWidget.WantsGlow: Boolean;
begin
  Result := False;
end;

{ fades the highlight in while the pointer is over the control and out again after it leaves }
procedure TGLWidget.GlowTick(Sender: TObject);
begin
  if FHover then FGlow := System.Math.Min(1.0, FGlow + 0.25)
  else FGlow := System.Math.Max(0.0, FGlow - 0.2);
  FGlowPhase := FGlowPhase + 0.11;
  if (not FHover) and (FGlow <= 0) then FGlowTimer.Enabled := False;
  Invalidate;
end;

procedure TGLWidget.DrawHoverGlow(cv: TGLCanvas; const R: TRect; ARadius: Integer);
var
  accent, deep: TColor;
  pulse, sweep: Double;
  sx, k: Integer;
begin
  if (FGlow < 0.02) or not Enabled then Exit;
  accent := AccentColor;
  deep := Blend(accent, clBlack, 0.35);
  pulse := 0.5 + 0.5 * FastSin(FGlowPhase);
  cv.Pen.Style := psClear;
  cv.Brush.Style := bsSolid;
  { a soft halo that breathes around the pill }
  cv.Brush.Color := accent;
  cv.Alpha := (0.10 + 0.16 * pulse) * FGlow;
  cv.RoundRect(R.Left - 2, R.Top - 2, R.Right + 2, R.Bottom + 2, ARadius + 3, ARadius + 3);
  cv.Alpha := FGlow;
  cv.Brush.Color := deep;
  cv.RoundRect(R.Left, R.Top, R.Right, R.Bottom, ARadius, ARadius);
  cv.Brush.Color := Blend(accent, clWhite, 0.06 + 0.14 * pulse);
  cv.RoundRect(R.Left, R.Top, R.Right, R.Bottom - 2, ARadius, ARadius);
  cv.Brush.Color := clWhite;
  cv.Alpha := 0.14 * FGlow;
  cv.RoundRect(R.Left + 2, R.Top + 1, R.Right - 2, R.Top + (R.Bottom - R.Top) div 2, ARadius - 2, ARadius - 2);
  { a slanted band of light that sweeps across the pill, left to right, over and over }
  cv.PushClip(Rect(R.Left + 1, R.Top + 1, R.Right - 1, R.Bottom - 1));
  sweep := Frac(FGlowPhase / 8.0);
  sx := R.Left - 40 + Round(sweep * (R.Right - R.Left + 80));
  cv.Brush.Color := clWhite;
  for k := 0 to 3 do
  begin
    cv.Alpha := (0.05 + 0.05 * k) * FGlow;
    cv.Polygon([Point(sx + k * 5 + 8, R.Top), Point(sx + 30 - k * 5 + 8, R.Top),
      Point(sx + 30 - k * 5 - 4, R.Bottom), Point(sx + k * 5 - 4, R.Bottom)]);
  end;
  cv.PopClip;
  cv.Alpha := 1;
end;

procedure TGLWidget.CMMouseLeave(var Msg: TMessage);
begin
  inherited;
  FHover := False;
  Invalidate;
end;

procedure TGLWidget.CMEnabledChanged(var Msg: TMessage);
begin
  inherited;
  Invalidate;
end;

procedure TGLWidget.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if (Key = VK_SPACE) and Enabled and not FPressed then
  begin
    FPressed := True;
    FHover := True;
    Invalidate;
    Key := 0;
  end;
end;

procedure TGLWidget.KeyUp(var Key: Word; Shift: TShiftState);
begin
  inherited KeyUp(Key, Shift);
  if (Key = VK_SPACE) and FPressed then
  begin
    FPressed := False;
    Invalidate;
    Key := 0;
    if Enabled then Activate;
  end;
end;

procedure TGLWidget.Activate;
begin
end;

procedure TGLWidget.WMSetFocus(var Msg: TWMSetFocus);
begin
  inherited;
  Invalidate;
end;

procedure TGLWidget.WMKillFocus(var Msg: TWMKillFocus);
begin
  inherited;
  Invalidate;
end;

{ text follows the control's Font, which inherits the form font by default }
procedure TGLWidget.PrepareCanvas(ACanvas: TGLCanvas);
begin
  inherited PrepareCanvas(ACanvas);
  ACanvas.Font.Name := Font.Name;
  if Font.Height <> 0 then ACanvas.Font.Height := Font.Height;
  ACanvas.Font.Style := Font.Style;
end;

function TGLWidget.ShownCaption: string;
begin
  Result := StringReplace(FCaption, '&&', #1, [rfReplaceAll]);
  Result := StringReplace(Result, '&', '', [rfReplaceAll]);
  Result := StringReplace(Result, #1, '&', [rfReplaceAll]);
end;

function TGLWidget.FieldColor: TColor;
begin
  Result := Sys(clWindow);
  if not Enabled then Result := Blend(Result, FaceColor, 0.5);
end;

procedure TGLWidget.DrawFocus(cv: TGLCanvas);
begin
  if not Focused then Exit;
  cv.Pen.Style := psSolid;
  cv.Pen.Color := AccentColor;
  cv.Brush.Style := bsClear;
  cv.RoundRect(0, 0, Width, Height, 7, 7);
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
end;

procedure TGLWidget.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button = mbLeft then
  begin
    if TabStop and CanFocus and not Focused then SetFocus;
    FPressed := True;
    Invalidate;
  end;
end;

procedure TGLWidget.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if Button = mbLeft then
  begin
    FPressed := False;
    Invalidate;
  end;
end;

function TGLWidget.BackdropColor: TColor;
var
  p: TWinControl;
  c: TColor;
begin
  p := Parent;
  while p <> nil do
  begin
    if p is TGLPage then Exit(FaceColor);   // a tab page paints the face colour: sit on it, not on what is behind the page
    if (p is TGLCollapsePanel) and (p = Parent) and (Top < TGLCollapsePanel(p).HeadHeight) then
      Exit(TGLCollapsePanel(p).HeadFillColor);   // a control sitting in the title bar
    if (p is TGLGroup) or (p is TGLRecessPanel) or (p is TGLCollapsePanel) then Exit(GroupBodyColor(FaceColor));
    if (p is TGLPanel) and (TGLPanel(p).Color <> clBtnFace) then Exit(Sys(TGLPanel(p).Color));
    if not (p is TGLPanel) and GLParentBackdrop(Self, c) then Exit(c);   // a form painting its own background
    p := p.Parent;
  end;
  Result := FaceColor;
end;

function TGLWidget.FaceColor: TColor;
begin
  Result := Sys(clBtnFace);
end;

function TGLWidget.InkColor: TColor;
begin
  if Enabled then Result := Sys(clBtnText)
  else Result := Blend(Sys(clBtnFace), Sys(clBtnText), 0.4);
end;

function TGLWidget.SelectionColor: TColor;
begin
  Result := ColorToRGB(CurrentTheme.ControlSelection);
  if not Enabled then Result := Blend(Sys(clBtnFace), Result, 0.3);
end;

function TGLWidget.SelectionTextColor: TColor;
begin
  Result := ColorToRGB(CurrentTheme.ControlSelectionText);
end;

function TGLWidget.HoverTint: TColor;
begin
  Result := ColorToRGB(CurrentTheme.ControlHover);
end;

function TGLWidget.FocusColor: TColor;
begin
  Result := ColorToRGB(CurrentTheme.ControlFocus);
end;

function TGLWidget.AccentColor: TColor;
begin
  if Enabled then Result := Sys(clHighlight)
  else Result := Blend(Sys(clBtnFace), Sys(clHighlight), 0.3);
end;

function TGLWidget.TrackColor: TColor;
begin
  Result := Blend(Sys(clBtnFace), Sys(clBtnText), 0.18);
end;

{ TGLButton }

constructor TGLButton.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  { Activate (on mouse up) raises the click itself; the VCL's own click on button up must not raise
    it a second time, or a click that opens a window opens it again once that window is closed }
  ControlStyle := ControlStyle - [csClickEvents];
  Width := 80;
  Height := 26;
end;

function TGLButton.WantsGlow: Boolean;
begin
  Result := True;
end;

procedure TGLButton.CMDialogKey(var Msg: TCMDialogKey);
begin
  if FDefault and (Msg.CharCode = VK_RETURN) and Enabled and Visible and
     not (GetKeyState(VK_MENU) < 0) then
  begin
    Activate;
    Msg.Result := 1;
  end
  else inherited;
end;

procedure TGLButton.Activate;
begin
  if FToggle then
  begin
    FDown := not FDown;
    if Assigned(FOnChange) then FOnChange(Self);
  end;
  Click;
end;

procedure TGLButton.SetDown(AValue: Boolean);
begin
  if FDown = AValue then Exit;
  FDown := AValue;
  Invalidate;
end;

procedure TGLButton.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  inside: Boolean;
begin
  inside := Pressed and PtInRect(ClientRect, Point(X, Y));
  inherited MouseUp(Button, Shift, X, Y);
  if (Button = mbLeft) and inside and Enabled then Activate;
end;

procedure TGLButton.PaintGL;
const
  DEPTH = 5;   // how far the raised face stands off the surface
var
  cv: TGLCanvas;
  face, c: TColor;
  tw, th, lift, w, h: Integer;
  faceRect: TRect;
  sunk: Boolean;
begin
  cv := GL;
  face := FaceColor;
  sunk := FDown or (Pressed and Hover);
  { a raised button stands DEPTH px proud of its shadow; pressed or latched it sinks into it }
  if sunk then lift := 1 else lift := DEPTH;
  w := Width; h := Height;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  { outside the rounded face the button shows what it sits on }
  cv.Brush.Color := BackdropColor;
  cv.FillRect(Rect(0, 0, w, h));
  if not Enabled then c := Blend(face, InkColor, 0.1)
  else if FDown then c := Blend(face, AccentColor, 0.55)
  else if Pressed and Hover then c := Blend(face, AccentColor, 0.45)
  else if Hover then c := Blend(face, InkColor, 0.16)
  else c := Blend(face, InkColor, 0.08);
  faceRect := Rect(1, 1 + (DEPTH - lift), w - 1, h - lift);
  { the cast shadow: a soft wide layer and a tighter dark one under the face edge }
  cv.Brush.Color := clBlack;
  cv.Alpha := 0.26;
  cv.RoundRect(0, faceRect.Top + 1, w, h, 10, 10);
  cv.Alpha := 0.34;
  cv.RoundRect(1, faceRect.Top + 2, w - 1, h, 9, 9);
  cv.Alpha := 0.55;
  cv.RoundRect(faceRect.Left, faceRect.Top + lift, faceRect.Right, h - 1, 7, 7);
  cv.Alpha := 1.0;
  { the button body, edge-lit from above }
  cv.Brush.Color := Blend(c, clBlack, 0.22);   // the visible side wall below the face
  cv.RoundRect(faceRect.Left, faceRect.Top + 1, faceRect.Right, faceRect.Bottom + 1, 7, 7);
  cv.Brush.Color := c;
  cv.RoundRect(faceRect.Left, faceRect.Top, faceRect.Right, faceRect.Bottom, 7, 7);
  if not sunk then
  begin
    { gloss: the upper half catches the light }
    cv.Alpha := 0.35;
    cv.GradientRect(Rect(faceRect.Left + 3, faceRect.Top + 1, faceRect.Right - 3,
      faceRect.Top + (faceRect.Bottom - faceRect.Top) div 2), Blend(c, clWhite, 0.55), c);
    cv.Alpha := 1.0;
  end
  else
  begin
    { pressed: the face is in shade, the top edge in the shadow of the rim }
    cv.Alpha := 0.25;
    cv.GradientRect(Rect(faceRect.Left + 3, faceRect.Top + 1, faceRect.Right - 3,
      faceRect.Top + 5), clBlack, c);
    cv.Alpha := 1.0;
  end;
  if not FDown then DrawHoverGlow(cv, faceRect, 7);
  cv.Pen.Style := psSolid;
  if FDown then cv.Pen.Color := Blend(face, AccentColor, 0.35)
  else cv.Pen.Color := Blend(face, InkColor, 0.35);
  cv.Brush.Style := bsClear;
  cv.RoundRect(faceRect.Left, faceRect.Top, faceRect.Right, faceRect.Bottom, 7, 7);
  if not sunk then
  begin
    { bright top edge }
    cv.Pen.Color := Blend(c, clWhite, 0.5);
    cv.MoveTo(faceRect.Left + 5, faceRect.Top + 1);
    cv.LineTo(faceRect.Right - 5, faceRect.Top + 1);
  end;
  cv.Brush.Style := bsSolid;
  cv.Font.Color := InkColor;
  tw := cv.TextWidth(ShownCaption);
  th := cv.TextHeight(ShownCaption);
  cv.TextOut((w - tw) div 2,
    faceRect.Top + (faceRect.Bottom - faceRect.Top - th) div 2, ShownCaption);
  DrawFocus(cv);
end;

{ TGLCheck }

constructor TGLCheck.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  Width := 120;
  Height := 22;
end;

procedure TGLCheck.Activate;
begin
  SetChecked(not FChecked);
  Click;
end;

procedure TGLCheck.SetChecked(AValue: Boolean);
begin
  if FChecked = AValue then Exit;
  FChecked := AValue;
  Invalidate;
  if Assigned(FOnChange) then FOnChange(Self);
end;

procedure TGLCheck.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  inside: Boolean;
begin
  inside := Pressed and PtInRect(ClientRect, Point(X, Y));
  inherited MouseUp(Button, Shift, X, Y);
  if (Button = mbLeft) and inside and Enabled then Activate;
end;

procedure TGLCheck.PaintGL;
var
  cv: TGLCanvas;
  face: TColor;
  bx, by: Integer;
begin
  cv := GL;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  { "transparent": filled with the colour it sits on (see TGLKnob.PaintGL) }
  face := BackdropColor;
  cv.Brush.Color := face;
  cv.FillRect(Rect(0, 0, Width, Height));
  bx := 2;
  by := (Height - 16) div 2 - 1;
  DrawDropShadow(cv, Rect(bx, by, bx + 16, by + 16), 5, 3);
  if FChecked then cv.Brush.Color := SelectionColor
  else if Hover then cv.Brush.Color := Blend(face, InkColor, 0.22)
  else cv.Brush.Color := TrackColor;
  cv.RoundRect(bx, by, bx + 16, by + 16, 5, 5);
  if not FChecked then
  begin
    cv.Pen.Style := psSolid;
    cv.Pen.Color := Blend(face, InkColor, 0.45);
    cv.Brush.Style := bsClear;
    cv.RoundRect(bx, by, bx + 16, by + 16, 5, 5);
    cv.Brush.Style := bsSolid;
  end;
  if FChecked then
  begin
    cv.Pen.Style := psSolid;
    cv.Pen.Width := 2;
    cv.Pen.Color := clWhite;
    cv.MoveTo(bx + 4, by + 8);
    cv.LineTo(bx + 7, by + 11);
    cv.LineTo(bx + 12, by + 5);
    cv.Pen.Width := 1;
  end;
  cv.Font.Color := InkColor;
  cv.TextOut(bx + 24, (Height - cv.TextHeight(ShownCaption)) div 2, ShownCaption);
  if Focused then
  begin
    cv.Pen.Style := psSolid;
    cv.Pen.Color := AccentColor;
    cv.Brush.Style := bsClear;
    cv.RoundRect(bx - 1, by - 1, bx + 17, by + 17, 6, 6);
    cv.Brush.Style := bsSolid;
  end;
end;

{ TGLValueWidget }

constructor TGLValueWidget.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FMin := 0;
  FMax := 100;
  FPos := 0;
  FDefault := 0;
  FDecimals := 1;
end;

procedure TGLValueWidget.SetMin(AValue: Double);
begin
  FMin := AValue;
  SetPos(FPos);
  Invalidate;
end;

procedure TGLValueWidget.SetMax(AValue: Double);
begin
  FMax := AValue;
  SetPos(FPos);
  Invalidate;
end;

procedure TGLValueWidget.SetPos(AValue: Double);
begin
  if FStep > 0 then AValue := FMin + Round((AValue - FMin) / FStep) * FStep;
  if FMax > FMin then AValue := EnsureRange(AValue, FMin, FMax) else AValue := FMin;
  if SameValue(AValue, FPos, 1e-12) then Exit;
  FPos := AValue;
  Invalidate;
  if Assigned(FOnChange) then FOnChange(Self);
end;

procedure TGLValueWidget.SetDecimals(AValue: Integer);
begin
  FDecimals := EnsureRange(AValue, 0, 6);
  Invalidate;
end;

function TGLValueWidget.Fraction: Double;
begin
  Result := FractionOf(FPos);
end;

function TGLValueWidget.FractionOf(AValue: Double): Double;
begin
  if FMax > FMin then Result := (AValue - FMin) / (FMax - FMin) else Result := 0;
end;

function TGLValueWidget.ValueAt(AFraction: Double): Double;
begin
  Result := FMin + AFraction * (FMax - FMin);
end;

function TGLValueWidget.ValueText: string;
begin
  Result := FloatToStrF(FPos, ffFixed, 15, FDecimals);
end;

procedure TGLValueWidget.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button = mbLeft) and Enabled then
  begin
    FDragX := X;
    FDragY := Y;
    FDragStart := FPos;
    DragTo(X, Y, ssShift in Shift);
  end;
end;

procedure TGLValueWidget.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseMove(Shift, X, Y);
  if Pressed and Enabled then DragTo(X, Y, ssShift in Shift);
end;

function TGLValueWidget.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  { Ctrl + wheel is left to whatever holds the control (the Timeline scrolls its lanes with it) }
  if ssCtrl in Shift then Exit(False);
  Result := True;
  if not Enabled then Exit;
  SetPos(ValueAt(EnsureRange(Fraction + Sign(WheelDelta) / IfThen(ssShift in Shift, 1000, 100), 0, 1)));
end;

procedure TGLValueWidget.DblClick;
begin
  inherited DblClick;
  if Enabled then SetPos(FDefault);
end;

{ TGLKnob }

constructor TGLKnob.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 56;
  Height := 72;
end;

procedure TGLKnob.SetLog(AValue: Boolean);
begin
  if FLog = AValue then Exit;
  FLog := AValue;
  Invalidate;
end;

function TGLKnob.IsLog: Boolean;
begin
  Result := FLog and (Min > 0) and (Max > Min);
end;

function TGLKnob.FractionOf(AValue: Double): Double;
begin
  if IsLog then
    Result := FastLn(System.Math.Max(AValue, Min) / Min) / FastLn(Max / Min)
  else
    Result := inherited FractionOf(AValue);
end;

function TGLKnob.ValueAt(AFraction: Double): Double;
begin
  if IsLog then
    Result := Min * FastExp(AFraction * FastLn(Max / Min))
  else
    Result := inherited ValueAt(AFraction);
end;

procedure TGLKnob.DragTo(X, Y: Integer; Fine: Boolean);
begin
  { vertical drag: full range over 200 px (1000 px with Shift) }
  SetPos(ValueAt(EnsureRange(FractionOf(DragStartPos) + (DragY - Y) / IfThen(Fine, 1000, 200), 0, 1)));
end;

procedure TGLKnob.PaintGL;
const
  A0 = 0.75 * Pi;
  Sweep = 1.5 * Pi;
var
  cv: TGLCanvas;
  face: TColor;
  cx, cy, r, i, n: Integer;
  a, aEnd: Double;
  procedure Arc(AFrom, ATo: Double; AWidth: Integer; AColor: TColor);
  var
    k, steps: Integer;
    t0, t1: Double;
  begin
    steps := System.Math.Max(2, Round(Abs(ATo - AFrom) * r / 3));
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
  end;
begin
  cv := GL;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  { "transparent": filled with the colour it sits on (each widget paints into its own frame, so an
    unfilled one would show whatever was drawn before it) }
  face := BackdropColor;
  cv.Brush.Color := face;
  cv.FillRect(Rect(0, 0, Width, Height));
  n := System.Math.Min(Width, Height - 28);
  r := n div 2 - 4;
  cx := Width shr 1;
  cy := r + 4;
  Arc(A0, A0 + Sweep, 4, TrackColor);
  aEnd := A0 + Sweep * Fraction;
  if Fraction > 0.001 then
    Arc(A0, aEnd, 4, IfThen(Hover or Pressed, Blend(AccentColor, clWhite, 0.2), AccentColor));
  cv.Pen.Style := psClear;
  cv.Brush.Color := Blend(face, InkColor, IfThen(Hover or Pressed, 0.2, 0.12));
  cv.Ellipse(cx - r + 7, cy - r + 7, cx + r - 6, cy + r - 6);
  a := aEnd;
  cv.Pen.Style := psSolid;
  cv.Pen.Width := 2;
  cv.Pen.Color := InkColor;
  i := r - 6;
  cv.MoveTo(cx + Round(FastCos(a) * (i * 0.35)), cy + Round(FastSin(a) * (i * 0.35)));
  cv.LineTo(cx + Round(FastCos(a) * i), cy + Round(FastSin(a) * i));
  cv.Pen.Width := 1;
  cv.Font.Color := InkColor;
  cv.TextOut((Width - cv.TextWidth(ValueText)) div 2, Height - 28, ValueText);
  cv.Font.Color := Blend(face, InkColor, 0.65);
  cv.TextOut((Width - cv.TextWidth(ShownCaption)) div 2, Height - 14, ShownCaption);
end;

{ ---- scroll-bar thumbs: glide + 3D bevel + menu-style highlight ---- }

type
  { one per view that draws scroll bars; found again by name, owned (and freed) by the view }
  TGLThumbGlide = class(TComponent)
  private
    FView: TGLView;
    FTimer: TTimer;
    FShown: array[0..1, 0..3] of Double;   // left, top, right, bottom as drawn
    FGoal: array[0..1] of TRect;
    FInit: array[0..1] of Boolean;
    FGlow, FPhase: Double;   // highlight fade 0..1 and the sweep / pulse phase
    FHot: Boolean;
    procedure Tick(Sender: TObject);
  public
    constructor Create(AView: TGLView); reintroduce;
    function Place(ASlot: Integer; const AGoal: TRect; ASnap, AHot: Boolean): TRect;
    property Glow: Double read FGlow;
    property Phase: Double read FPhase;
  end;

constructor TGLThumbGlide.Create(AView: TGLView);
begin
  inherited Create(AView);
  Name := 'ThumbGlide';
  FView := AView;
  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := 15;
  FTimer.OnTimer := Tick;
end;

procedure TGLThumbGlide.Tick(Sender: TObject);
var
  sl, k: Integer;
  g: array[0..3] of Integer;
  moving: Boolean;
begin
  moving := False;
  for sl := 0 to 1 do
  begin
    if not FInit[sl] then Continue;
    g[0] := FGoal[sl].Left; g[1] := FGoal[sl].Top; g[2] := FGoal[sl].Right; g[3] := FGoal[sl].Bottom;
    for k := 0 to 3 do
    begin
      FShown[sl, k] := FShown[sl, k] + (g[k] - FShown[sl, k]) * 0.22;
      if Abs(g[k] - FShown[sl, k]) < 0.5 then FShown[sl, k] := g[k]
      else moving := True;
    end;
  end;
  if FHot then FGlow := System.Math.Min(1.0, FGlow + 0.25)
  else FGlow := System.Math.Max(0.0, FGlow - 0.2);
  FPhase := FPhase + 0.11;
  { keeps running while the thumb is lit so its sweep stays alive }
  if not (moving or FHot or (FGlow > 0)) then FTimer.Enabled := False;
  FView.Invalidate;
end;

function TGLThumbGlide.Place(ASlot: Integer; const AGoal: TRect; ASnap, AHot: Boolean): TRect;
var
  k: Integer;
  g: array[0..3] of Integer;
begin
  FGoal[ASlot] := AGoal;
  FHot := AHot;
  if (AHot or (FGlow > 0)) and not FTimer.Enabled then FTimer.Enabled := True;
  g[0] := AGoal.Left; g[1] := AGoal.Top; g[2] := AGoal.Right; g[3] := AGoal.Bottom;
  if ASnap or not FInit[ASlot] or (csDesigning in ComponentState) then
  begin
    FInit[ASlot] := True;
    for k := 0 to 3 do FShown[ASlot, k] := g[k];
  end
  else
    for k := 0 to 3 do
      if (Abs(g[k] - FShown[ASlot, k]) >= 0.5) and not FTimer.Enabled then FTimer.Enabled := True;
  Result := Rect(Round(FShown[ASlot, 0]), Round(FShown[ASlot, 1]), Round(FShown[ASlot, 2]), Round(FShown[ASlot, 3]));
end;

procedure GLDrawScrollThumb(cv: TGLCanvas; AView: TGLView; ASlot: Integer; const AGoal: TRect;
  AVertical, AActive, AHot: Boolean; AField, AInk, AAccent: TColor);
var
  gl: TGLThumbGlide;
  R, zone: TRect;
  base, hi, lo, edge: TColor;
  i, n, len, sx, k: Integer;
  t, glow: Double;
begin
  gl := TGLThumbGlide(AView.FindComponent('ThumbGlide'));
  if gl = nil then gl := TGLThumbGlide.Create(AView);
  { lit while dragged, or while the pointer is over the bar itself }
  if AVertical then zone := Rect(AGoal.Left - 2, 0, AView.Width, AView.Height)
  else zone := Rect(0, AGoal.Top - 2, AView.Width, AView.Height);
  AHot := AHot and PtInRect(zone, AView.ScreenToClient(Mouse.CursorPos));
  R := gl.Place(ASlot, AGoal, AActive, AHot or AActive);
  if (R.Right - R.Left < 3) or (R.Bottom - R.Top < 3) then Exit;
  if AActive then base := AAccent
  else if AHot then base := Blend(AField, AInk, 0.55)
  else base := Blend(AField, AInk, 0.42);
  hi := Blend(base, clWhite, 0.38);
  lo := Blend(base, clBlack, 0.38);
  edge := Blend(base, clBlack, 0.72);
  cv.Pen.Style := psClear;
  cv.Brush.Style := bsSolid;
  { a soft shadow under and beside the thumb lifts it off the track }
  cv.Brush.Color := clBlack;
  cv.Alpha := 0.38;
  cv.RoundRect(R.Left + 1, R.Top + 1, R.Right + 1, R.Bottom + 1, 6, 6);
  cv.Alpha := 1;
  { dark outer rim, then the rounded body inside it }
  cv.Brush.Color := edge;
  cv.RoundRect(R.Left, R.Top, R.Right, R.Bottom, 6, 6);
  { the body is shaded across the thumb (cylinder): light on the top / left, dark on the bottom / right }
  if AVertical then n := R.Right - R.Left - 2 else n := R.Bottom - R.Top - 2;
  for i := 0 to n - 1 do
  begin
    t := i / System.Math.Max(1, n - 1);
    if t < 0.35 then cv.Brush.Color := Blend(hi, base, t / 0.35)
    else cv.Brush.Color := Blend(base, lo, (t - 0.35) / 0.65);
    if AVertical then
      cv.FillRect(Rect(R.Left + 1 + i, R.Top + 3, R.Left + 2 + i, R.Bottom - 3))
    else
      cv.FillRect(Rect(R.Left + 3, R.Top + 1 + i, R.Right - 3, R.Top + 2 + i));
  end;
  { bevel: a bright lip along the top / left edges, a dark one along the bottom / right }
  cv.Brush.Color := Blend(base, clWhite, 0.8);
  if AVertical then
    cv.FillRect(Rect(R.Left + 1, R.Top + 4, R.Left + 2, R.Bottom - 4))
  else
    cv.FillRect(Rect(R.Left + 4, R.Top + 1, R.Right - 4, R.Top + 2));
  cv.FillRect(Rect(R.Left + 3, R.Top + 1, R.Right - 3, R.Top + 2));
  cv.Brush.Color := Blend(base, clBlack, 0.8);
  if AVertical then
    cv.FillRect(Rect(R.Right - 2, R.Top + 4, R.Right - 1, R.Bottom - 4))
  else
    cv.FillRect(Rect(R.Left + 4, R.Bottom - 2, R.Right - 4, R.Bottom - 1));
  cv.FillRect(Rect(R.Left + 3, R.Bottom - 2, R.Right - 3, R.Bottom - 1));
  { the menus' selection look: an accent glow over the thumb with a band of light sweeping along the
    bar - down a vertical bar, across a horizontal one }
  glow := gl.Glow;
  if glow > 0.02 then
  begin
    cv.Brush.Color := AAccent;
    cv.Alpha := 0.45 * glow;
    cv.RoundRect(R.Left + 1, R.Top + 1, R.Right - 1, R.Bottom - 1, 5, 5);
    cv.PushClip(Rect(R.Left + 1, R.Top + 1, R.Right - 1, R.Bottom - 1));
    cv.Brush.Color := clWhite;
    if AVertical then
    begin
      sx := R.Top - 24 + Round(Frac(gl.Phase / 8.0) * (R.Bottom - R.Top + 48));
      for k := 0 to 3 do
      begin
        cv.Alpha := (0.05 + 0.05 * k) * glow;
        cv.Polygon([Point(R.Left, sx + k * 3 + 8), Point(R.Right, sx + k * 3 + 2),
          Point(R.Right, sx + 22 - k * 3), Point(R.Left, sx + 28 - k * 3)]);
      end;
    end
    else
    begin
      sx := R.Left - 24 + Round(Frac(gl.Phase / 8.0) * (R.Right - R.Left + 48));
      for k := 0 to 3 do
      begin
        cv.Alpha := (0.05 + 0.05 * k) * glow;
        cv.Polygon([Point(sx + k * 3 + 8, R.Top), Point(sx + k * 3 + 2, R.Bottom),
          Point(sx + 22 - k * 3, R.Bottom), Point(sx + 28 - k * 3, R.Top)]);
      end;
    end;
    cv.PopClip;
    cv.Alpha := 1;
  end;
  { grip ridges in the middle of a long enough thumb }
  if AVertical then len := R.Bottom - R.Top else len := R.Right - R.Left;
  if len >= 26 then
    for i := -1 to 1 do
    begin
      if AVertical then
      begin
        cv.Brush.Color := edge;
        cv.FillRect(Rect(R.Left + 3, (R.Top + R.Bottom) div 2 + i * 3, R.Right - 3, (R.Top + R.Bottom) div 2 + i * 3 + 1));
        cv.Brush.Color := hi;
        cv.FillRect(Rect(R.Left + 3, (R.Top + R.Bottom) div 2 + i * 3 + 1, R.Right - 3, (R.Top + R.Bottom) div 2 + i * 3 + 2));
      end
      else
      begin
        cv.Brush.Color := edge;
        cv.FillRect(Rect((R.Left + R.Right) div 2 + i * 3, R.Top + 3, (R.Left + R.Right) div 2 + i * 3 + 1, R.Bottom - 3));
        cv.Brush.Color := hi;
        cv.FillRect(Rect((R.Left + R.Right) div 2 + i * 3 + 1, R.Top + 3, (R.Left + R.Right) div 2 + i * 3 + 2, R.Bottom - 3));
      end;
    end;
end;

procedure GLDrawSliderKnob(cv: TGLCanvas; const R: TRect; ABase: TColor; AHot, AGripAcross: Boolean);
var
  y, h, mid: Integer;
  hi, lo, edge: TColor;
begin
  h := R.Bottom - R.Top;
  cv.Pen.Style := psClear;
  cv.Brush.Style := bsSolid;
  { drop shadow: two soft layers, offset down and right of the knob }
  cv.Brush.Color := clBlack;
  cv.Alpha := 0.16;
  cv.RoundRect(R.Left - 1, R.Top + 2, R.Right + 4, R.Bottom + 6, 7, 7);
  cv.Alpha := 0.30;
  cv.RoundRect(R.Left + 1, R.Top + 3, R.Right + 3, R.Bottom + 4, 6, 6);
  cv.Alpha := 1;
  if AHot then ABase := Blend(ABase, clWhite, 0.12);
  hi := Blend(ABase, clWhite, 0.45);
  lo := Blend(ABase, clBlack, 0.35);
  edge := Blend(ABase, clBlack, 0.65);
  cv.Brush.Color := edge;
  cv.RoundRect(R.Left, R.Top, R.Right, R.Bottom, 6, 6);
  { body: a light-to-dark gradient, one row at a time, inside the outline }
  for y := R.Top + 1 to R.Bottom - 2 do
  begin
    cv.Brush.Color := Blend(hi, lo, (y - R.Top - 1) / System.Math.Max(1, h - 3));
    if (y = R.Top + 1) or (y = R.Bottom - 2) then
      cv.FillRect(Rect(R.Left + 2, y, R.Right - 2, y + 1))
    else
      cv.FillRect(Rect(R.Left + 1, y, R.Right - 1, y + 1));
  end;
  { bright top lip and dark underside give the cap its thickness }
  cv.Brush.Color := Blend(ABase, clWhite, 0.75);
  cv.FillRect(Rect(R.Left + 3, R.Top + 1, R.Right - 3, R.Top + 2));
  cv.Brush.Color := edge;
  cv.FillRect(Rect(R.Left + 3, R.Bottom - 2, R.Right - 3, R.Bottom - 1));
  { grip groove: a dark line with a light line beside it }
  if AGripAcross then
  begin
    mid := (R.Top + R.Bottom) div 2;
    cv.Brush.Color := edge;
    cv.FillRect(Rect(R.Left + 4, mid - 1, R.Right - 4, mid));
    cv.Brush.Color := Blend(ABase, clWhite, 0.6);
    cv.FillRect(Rect(R.Left + 4, mid, R.Right - 4, mid + 1));
  end
  else
  begin
    mid := (R.Left + R.Right) div 2;
    cv.Brush.Color := edge;
    cv.FillRect(Rect(mid - 1, R.Top + 4, mid, R.Bottom - 4));
    cv.Brush.Color := Blend(ABase, clWhite, 0.6);
    cv.FillRect(Rect(mid, R.Top + 4, mid + 1, R.Bottom - 4));
  end;
end;

{ TGLSlider }

constructor TGLSlider.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 140;
  Height := 24;
end;

procedure TGLSlider.SetVertical(AValue: Boolean);
begin
  if FVertical = AValue then Exit;
  FVertical := AValue;
  if (csDesigning in ComponentState) and not (csLoading in ComponentState) then
    SetBounds(Left, Top, Height, Width);
  Invalidate;
end;

function TGLSlider.TrackRect: TRect;
begin
  if FVertical then Result := Rect(Width shr 1 - 2, 8, Width shr 1 + 2, Height - 8)
  else Result := Rect(8, Height shr 1 - 2, Width - 8, Height shr 1 + 2);
end;

procedure TGLSlider.DragTo(X, Y: Integer; Fine: Boolean);
var
  tr: TRect;
  f: Double;
begin
  tr := TrackRect;
  if FVertical then f := (tr.Bottom - Y) / System.Math.Max(1, tr.Bottom - tr.Top)
  else f := (X - tr.Left) / System.Math.Max(1, tr.Right - tr.Left);
  if Fine then f := (DragStartPos - Min) / System.Math.Max(1e-12, Max - Min) + (f - (DragStartPos - Min) / System.Math.Max(1e-12, Max - Min)) * 0.1;
  SetPos(Min + EnsureRange(f, 0, 1) * (Max - Min));
end;

procedure TGLSlider.PaintGL;
var
  cv: TGLCanvas;
  face: TColor;
  tr: TRect;
  tx, ty: Integer;
begin
  cv := GL;
  face := FaceColor;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := face;
  cv.FillRect(Rect(0, 0, Width, Height));
  tr := TrackRect;
  DrawDropShadow(cv, tr, 4, 2);
  cv.Brush.Color := TrackColor;
  cv.RoundRect(tr.Left, tr.Top, tr.Right, tr.Bottom, 4, 4);
  cv.Brush.Color := AccentColor;
  if FVertical then
  begin
    ty := tr.Bottom - Round((tr.Bottom - tr.Top) * Fraction);
    if ty < tr.Bottom then cv.RoundRect(tr.Left, ty, tr.Right, tr.Bottom, 4, 4);
    DrawInsetShadow(cv, tr, 2);
    GLDrawSliderKnob(cv, Rect(Width shr 1 - 10, ty - 8, Width shr 1 + 10, ty + 8), InkColor,
      Hover or Pressed, True);
  end
  else
  begin
    tx := tr.Left + Round((tr.Right - tr.Left) * Fraction);
    if tx > tr.Left then cv.RoundRect(tr.Left, tr.Top, tx, tr.Bottom, 4, 4);
    DrawInsetShadow(cv, tr, 2);
    GLDrawSliderKnob(cv, Rect(tx - 8, Height shr 1 - 10, tx + 8, Height shr 1 + 10), InkColor,
      Hover or Pressed, False);
  end;
end;

{ TGLEqSlider }

constructor TGLEqSlider.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Vertical := True;
  Width := 37;
  Height := 150;
end;

procedure TGLEqSlider.PaintGL;
const
  FACE_TOP = TColor($2A2018);
  FACE_BOT = TColor($100B09);
  LINE_MINOR = TColor($54463A);   { every 1 dB }
  LINE_MID = TColor($7A6650);     { every 3 dB }
  LINE_MAJOR = TColor($A58660);   { every 6 dB }
  LINE_ZERO = TColor($E0A860);
  GROOVE = TColor($050403);
  FILL = TColor($E8A838);
var
  cv: TGLCanvas;
  top, bot, cx, y, ky, zy: Integer;
  db, span: Double;
  bg: TColor;
begin
  cv := GL;
  top := 8;
  bot := Height - 8;   { the travel TGLSlider.DragTo maps the pointer onto }
  cx := Width shr 1;
  span := System.Math.Max(1e-9, Max - Min);
  cv.Pen.Style := psClear;
  cv.Brush.Style := bsSolid;
  for y := 0 to Height - 1 do
  begin
    cv.Brush.Color := Blend(FACE_TOP, FACE_BOT, y / System.Math.Max(1, Height - 1));
    cv.FillRect(Rect(0, y, Width, y + 1));
  end;
  { horizontal rules every dB: fainter ones between, stronger every 3 and 6 dB, the 0 dB one lit }
  db := Max;
  while db >= Min - 0.001 do
  begin
    y := bot - Round((bot - top) * (db - Min) / span);
    if Abs(db) < 0.001 then bg := LINE_ZERO
    else if Abs(Round(db)) mod 6 = 0 then bg := LINE_MAJOR
    else if Abs(Round(db)) mod 3 = 0 then bg := LINE_MID
    else bg := LINE_MINOR;
    cv.Brush.Color := bg;
    cv.FillRect(Rect(0, y, Width, y + 1));
    db := db - 1;
  end;
  { groove, lit from the 0 dB line to the knob }
  cv.Brush.Color := GROOVE;
  cv.RoundRect(cx - 3, top - 4, cx + 3, bot + 4, 4, 4);
  ky := bot - Round((bot - top) * Fraction);
  zy := bot - Round((bot - top) * (0 - Min) / span);
  cv.Brush.Color := FILL;
  if ky < zy then cv.FillRect(Rect(cx - 1, ky, cx + 1, zy))
  else if ky > zy then cv.FillRect(Rect(cx - 1, zy, cx + 1, ky));
  { a hair line between neighbouring faces }
  cv.Brush.Color := TColor($0A0706);
  cv.FillRect(Rect(Width - 1, 0, Width, Height));
  GLDrawSliderKnob(cv, Rect(cx - 12, ky - 8, cx + 12, ky + 8), InkColor, Hover or Pressed, True);
  DrawFocus(cv);
end;

{ TGLLabel }

constructor TGLLabel.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FTransparent := True;
  Width := 65;
  Height := 17;
  AutoSize := True;
end;

procedure TGLLabel.SetAlignment(AValue: TAlignment);
begin
  FAlignment := AValue;
  Invalidate;
end;

procedure TGLLabel.SetLayout(AValue: TTextLayout);
begin
  FLayout := AValue;
  Invalidate;
end;

procedure TGLLabel.SetWordWrap(AValue: Boolean);
begin
  FWordWrap := AValue;
  AdjustSize;
  Invalidate;
end;

procedure TGLLabel.CaptionChanged;
begin
  AdjustSize;
end;

procedure TGLLabel.CMFontChanged(var Msg: TMessage);
begin
  inherited;
  AdjustSize;
  Invalidate;
end;

{ as wide as the text and one line high, like TLabel }
function TGLLabel.CanAutoSize(var NewWidth, NewHeight: Integer): Boolean;
var
  bmp: TBitmap;
begin
  Result := True;
  if FWordWrap then Exit;
  bmp := TBitmap.Create;
  try
    bmp.Canvas.Font.Assign(Font);
    NewWidth := bmp.Canvas.TextWidth(ShownCaption) + 2;
    NewHeight := bmp.Canvas.TextHeight('Ag');
  finally
    bmp.Free;
  end;
end;

procedure TGLLabel.SetSunken(AValue: Boolean);
begin
  if FSunken = AValue then Exit;
  FSunken := AValue;
  Invalidate;
end;

procedure TGLLabel.PaintGL;
var
  cv: TGLCanvas;
  x, y, lineH: Integer;
  line, word, cur: string;
  words: TArray<string>;
begin
  cv := GL;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := BackdropColor;
  cv.FillRect(Rect(0, 0, Width, Height));
  if FSunken then DrawBox3D(cv, Rect(0, 0, Width, Height), BackdropColor, False, 8);
  if Enabled then cv.Font.Color := Sys(Font.Color)
  else cv.Font.Color := Blend(FaceColor, Sys(Font.Color), 0.4);
  line := ShownCaption;
  lineH := cv.TextHeight('Ag');
  if not FWordWrap then
  begin
    case FAlignment of
      taRightJustify: x := Width - cv.TextWidth(line) - IfThen(FSunken, 9, 0);
      taCenter: x := (Width - cv.TextWidth(line)) div 2;
    else
      x := IfThen(FSunken, 9, 0);
    end;
    case FLayout of
      tlCenter: y := (Height - lineH) div 2;
      tlBottom: y := Height - lineH;
    else
      y := 0;
    end;
    cv.TextOut(x, y, line);
    Exit;
  end;
  y := 0;
  cur := '';
  words := line.Split([' ']);
  for word in words do
  begin
    if (cur <> '') and (cv.TextWidth(cur + ' ' + word) > Width) then
    begin
      cv.TextOut(0, y, cur);
      Inc(y, lineH);
      cur := word;
    end
    else if cur = '' then cur := word
    else cur := cur + ' ' + word;
  end;
  if cur <> '' then cv.TextOut(0, y, cur);
end;

{ TGLGroup }

constructor TGLGroup.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csAcceptsControls, csSetCaption];
  TabStop := False;
  Width := 185;
  Height := 105;
end;

procedure TGLGroup.PaintGL;
var
  cv: TGLCanvas;
  face: TColor;
  cap: string;
  th, tw: Integer;
begin
  cv := GL;
  face := FaceColor;
  cap := ShownCaption;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := face;
  cv.FillRect(Rect(0, 0, Width, Height));
  th := cv.TextHeight('Ag');
  { a rounded box in one flat body colour, with its caption on a small raised tab }
  cv.Brush.Color := Blend(face, clBlack, 0.26);
  cv.RoundRect(0, th div 2, Width, Height, 18, 18);
  cv.Brush.Color := GroupBodyColor(face);
  cv.RoundRect(1, th div 2 + 1, Width - 1, Height - 1, 16, 16);
  DrawInsetShadow(cv, Rect(2, th div 2 + 2, Width - 2, Height - 2), 4);
  if cap <> '' then
  begin
    tw := cv.TextWidth(cap);
    DrawDropShadow(cv, Rect(8, 0, 8 + tw + 16, th + 2), 6, 3);
    DrawBox3D(cv, Rect(8, 0, 8 + tw + 16, th + 2), face, True, 6);
    cv.Brush.Style := bsClear;
    cv.Font.Color := InkColor;
    cv.TextOut(16, 1, cap);
    cv.Brush.Style := bsSolid;
  end;
end;

{ TGLPanel }

constructor TGLPanel.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csAcceptsControls];
  FBevelOuter := bvRaised;
  FBevelEdges := [beLeft, beTop, beRight, beBottom];
  FShowCaption := True;
  FParentBackground := True;
  Color := clBtnFace;
  TabStop := False;
  Width := 185;
  Height := 41;
end;

procedure TGLPanel.SetBevelOuter(AValue: TPanelBevel);
begin
  FBevelOuter := AValue;
  Invalidate;
end;

procedure TGLPanel.SetBevelKind(AValue: TBevelKind);
begin
  FBevelKind := AValue;
  Invalidate;
end;

procedure TGLPanel.SetBevelEdges(AValue: TBevelEdges);
begin
  FBevelEdges := AValue;
  Invalidate;
end;

procedure TGLPanel.SetShowCaption(AValue: Boolean);
begin
  FShowCaption := AValue;
  Invalidate;
end;

procedure TGLPanel.CaptionChanged;
begin
  Invalidate;
end;

procedure TGLPanel.Resize;
begin
  inherited Resize;
  if Assigned(FOnResize) then FOnResize(Self);
end;

procedure TGLPanel.PaintGL;
var
  cv: TGLCanvas;
  face, line: TColor;
  cap: string;
begin
  cv := GL;
  face := FaceColor;
  { the style's face colour unless the panel was given a colour of its own }
  if Color <> clBtnFace then face := Sys(Color);
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := face;
  cv.FillRect(Rect(0, 0, Width, Height));
  line := Blend(face, InkColor, 0.28);
  cv.Brush.Color := line;
  if FBevelKind <> bkNone then
  begin
    if beLeft in FBevelEdges then cv.FillRect(Rect(0, 0, 1, Height));
    if beTop in FBevelEdges then cv.FillRect(Rect(0, 0, Width, 1));
    if beRight in FBevelEdges then cv.FillRect(Rect(Width - 1, 0, Width, Height));
    if beBottom in FBevelEdges then cv.FillRect(Rect(0, Height - 1, Width, Height));
  end
  else if (FBevelOuter in [bvRaised, bvLowered]) and (Color = clBtnFace) and (Width > 12) and (Height > 12) then
    DrawBox3D(cv, Rect(0, 0, Width, Height), face, FBevelOuter = bvRaised, 8)
  else if FBevelOuter <> bvNone then
  begin
    cv.FillRect(Rect(0, 0, Width, 1));
    cv.FillRect(Rect(0, 0, 1, Height));
    cv.FillRect(Rect(Width - 1, 0, Width, Height));
    cv.FillRect(Rect(0, Height - 1, Width, Height));
  end;
  cap := ShownCaption;
  if FShowCaption and (cap <> '') then
  begin
    if Enabled then cv.Font.Color := Sys(Font.Color) else cv.Font.Color := Blend(face, Sys(Font.Color), 0.4);
    cv.TextOut((Width - cv.TextWidth(cap)) div 2, (Height - cv.TextHeight(cap)) div 2, cap);
  end;
end;

{ TGLRecessPanel }

function TGLRecessPanel.GLBackdropColor(const ARect: TRect): TColor;
begin
  Result := GroupBodyColor(FaceColor);
end;

procedure TGLRecessPanel.PaintGL;
var
  cv: TGLCanvas;
  face: TColor;
begin
  cv := GL;
  face := FaceColor;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := face;
  cv.FillRect(Rect(0, 0, Width, Height));
  { rim, then the flat body inside it, shaded from the top and left }
  cv.Brush.Color := Blend(face, clBlack, 0.26);
  cv.RoundRect(0, 0, Width, Height, 16, 16);
  cv.Brush.Color := GroupBodyColor(face);
  cv.RoundRect(1, 1, Width - 1, Height - 1, 14, 14);
  { the recess is shown by hairlines on the very edge: the controls on the panel (labels, icon
    bars, fields) fill their own rectangle with the body colour, so a wide shaded band inside the
    edge would be cut into by them and look like lighter blocks behind them }
  cv.Brush.Color := clBlack;
  cv.Alpha := 0.45;
  cv.FillRect(Rect(8, 1, Width - 8, 2));
  cv.Alpha := 0.35;
  cv.FillRect(Rect(1, 8, 2, Height - 8));
  cv.Brush.Color := clWhite;
  cv.Alpha := 0.12;
  cv.FillRect(Rect(8, Height - 2, Width - 8, Height - 1));
  cv.Alpha := 1;
end;

{ TGLCollapsePanel }

const
  COLLAPSE_HEAD_H = 32;   { the default }      { height of the title-bar segment: tall enough for a 22 px field and its shadow }
  COLLAPSE_STRIP_W = 26;     { width of the collapsed strip }
  COLLAPSE_INSET = 5;        { a collapsed strip sits this far right of its left-hand neighbour }

constructor TGLCollapsePanel.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FHidden := TList.Create;
  FHeadH := COLLAPSE_HEAD_H;
  FCornerColor := clNone;
  FHeadColor := clNone;
  FAutoPlace := True;
  BevelOuter := bvNone;
  ShowCaption := False;
  Cursor := crDefault;
end;

destructor TGLCollapsePanel.Destroy;
begin
  FHidden.Free;
  inherited Destroy;
end;

{ the title-bar colour: the theme's own, or HeadColor }
function TGLCollapsePanel.HeadFillColor: TColor;
begin
  if FHeadColor <> clNone then Result := ColorToRGB(FHeadColor)
  else Result := Blend(FaceColor, InkColor, 0.13);
end;

function TGLCollapsePanel.GLBackdropColor(const ARect: TRect): TColor;
begin
  if (ARect.Top < FHeadH) or (FCollapsed and (FMode = cmStrip)) then Result := HeadFillColor
  else Result := GroupBodyColor(FaceColor);
end;

procedure TGLCollapsePanel.SetCornerColor(AValue: TColor);
begin
  if FCornerColor = AValue then Exit;
  FCornerColor := AValue;
  Invalidate;
end;

procedure TGLCollapsePanel.SetHeadHeight(AValue: Integer);
begin
  AValue := EnsureRange(AValue, 20, 80);
  if FHeadH = AValue then Exit;
  FHeadH := AValue;
  Invalidate;
end;

procedure TGLCollapsePanel.SetTitle(const AValue: string);
begin
  if FTitle = AValue then Exit;
  FTitle := AValue;
  Invalidate;
end;

procedure TGLCollapsePanel.SetHeadColor(AValue: TColor);
begin
  if FHeadColor = AValue then Exit;
  FHeadColor := AValue;
  Invalidate;
end;

procedure TGLCollapsePanel.SetCollapsed(AValue: Boolean);
begin
  if FCollapsed = AValue then Exit;
  FCollapsed := AValue;
  if not (csLoading in ComponentState) then
  begin
    ApplyCollapsed;
    if Assigned(FOnToggle) then FOnToggle(Self);
  end;
end;

procedure TGLCollapsePanel.ApplyCollapsed;
var
  i, x: Integer;
begin
  if csDesigning in ComponentState then
  begin
    Invalidate;
    Exit;
  end;
  if FCollapsed then
  begin
    FExpLeft := Left;
    FExpWidth := Width;
    FExpHeight := Height;
    FHidden.Clear;
    for i := 0 to ControlCount - 1 do
      if Controls[i].Visible then
      begin
        FHidden.Add(Controls[i]);
        Controls[i].Visible := False;
      end;
    if FMode = cmBar then
    begin
      Height := FHeadH + 3;
      Invalidate;
      Exit;
    end;
    if not FAutoPlace then
    begin
      Width := COLLAPSE_STRIP_W;
      Invalidate;
      Exit;
    end;
    { start COLLAPSE_INSET to the right of whatever sits to the left of the panel }
    x := 0;
    if Parent <> nil then
      for i := 0 to Parent.ControlCount - 1 do
        with Parent.Controls[i] do
          if (Parent.Controls[i] <> Self) and Visible and (Left + Width <= FExpLeft) and
             (Top < Self.Top + Self.Height) and (Top + Height > Self.Top) and (Left + Width > x) then
            x := Left + Width;
    if x = 0 then x := FExpLeft - COLLAPSE_INSET;
    SetBounds(x + COLLAPSE_INSET, Top, COLLAPSE_STRIP_W, Height);
  end
  else
  begin
    if FMode = cmBar then
    begin
      if FExpHeight > 0 then Height := FExpHeight;
    end
    else if not FAutoPlace then
    begin
      if FExpWidth > 0 then Width := FExpWidth;
    end
    else if FExpWidth > 0 then SetBounds(FExpLeft, Top, FExpWidth, Height);
    for i := 0 to FHidden.Count - 1 do TControl(FHidden[i]).Visible := True;
    FHidden.Clear;
  end;
  Invalidate;
end;

procedure TGLCollapsePanel.Loaded;
begin
  inherited Loaded;
  if FCollapsed then ApplyCollapsed;
end;

procedure TGLCollapsePanel.CMMouseLeave(var Msg: TMessage);
begin
  inherited;
  if FHoverHead then
  begin
    FHoverHead := False;
    Invalidate;
  end;
end;

procedure TGLCollapsePanel.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  h: Boolean;
begin
  inherited MouseMove(Shift, X, Y);
  h := FCollapsed or (Y < FHeadH);
  if h <> FHoverHead then
  begin
    FHoverHead := h;
    Invalidate;
  end;
end;

procedure TGLCollapsePanel.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if (Button = mbLeft) and (FCollapsed or (Y < FHeadH)) and
     PtInRect(Rect(0, 0, Width, Height), Point(X, Y)) then
    SetCollapsed(not FCollapsed);
end;

procedure TGLCollapsePanel.PaintGL;
var
  cv: TGLCanvas;
  face, head, ink, arrow, headInk: TColor;
  cx, cy: Integer;
begin
  cv := GL;
  face := FaceColor;
  ink := InkColor;
  head := Blend(face, ink, 0.13);
  headInk := ink;
  if FHeadColor <> clNone then
  begin
    head := ColorToRGB(FHeadColor);
    { black or white text, whichever reads better on the colour }
    if ((head and $FF) * 299 + ((head shr 8) and $FF) * 587 + ((head shr 16) and $FF) * 114) > 140000 then
      headInk := clBlack
    else
      headInk := clWhite;
  end;
  if FHoverHead and (FHeadColor = clNone) then arrow := AccentColor else arrow := headInk;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  { the corners outside the rounded frame show what the panel sits on }
  if FCornerColor <> clNone then cv.Brush.Color := ColorToRGB(FCornerColor)
  else cv.Brush.Color := BackdropColor;
  cv.FillRect(Rect(0, 0, Width, Height));
  { a raised frame (lit from above, shaded underneath) ... }
  DrawBox3D(cv, Rect(0, 0, Width, Height), head, True, 12);
  if FCollapsed and (FMode = cmStrip) then
  begin
    { ... around an inset strip: its rim, a dark flat body and a shade from the top and left }
    cv.Brush.Color := Blend(head, clBlack, 0.55);
    cv.RoundRect(3, 3, Width - 3, Height - 3, 9, 9);
    cv.Brush.Color := Blend(head, clBlack, 0.62);
    cv.RoundRect(4, 4, Width - 4, Height - 4, 8, 8);
    DrawInsetShadow(cv, Rect(4, 4, Width - 4, Height - 4), 3);
    cx := Width shr 1;
    if FHoverHead then arrow := AccentColor else arrow := Blend(head, clWhite, 0.8);
    cv.Brush.Color := arrow;
    cv.Polygon([Point(cx - 3, 11), Point(cx - 3, 23), Point(cx + 4, 17)]);
    if FTitle <> '' then
    begin
      cv.Font.Color := Blend(head, clWhite, 0.85);
      cv.PushClip(Rect(5, 30, Width - 5, Height - 8));
      cv.TextOutVertical(cx - cv.TextHeight(FTitle) div 2 - 1, 34, FTitle);
      cv.PopClip;
    end;
    Exit;
  end;
  { ... around an inset body: its rim, then one flat colour that the controls on the panel paint over }
  cv.Brush.Color := Blend(head, clBlack, 0.45);
  cv.RoundRect(3, 3, Width - 3, Height - 3, 9, 9);
  cv.Brush.Color := GroupBodyColor(face);
  cv.RoundRect(4, 4, Width - 4, Height - 4, 8, 8);
  DrawInsetShadow(cv, Rect(4, 4, Width - 4, Height - 4), 3);
  { the title-bar segment, raised: rounded on top, square where it meets the body, with a lit top
    lip and a dark lower edge }
  cv.Brush.Color := head;
  cv.RoundRect(4, 4, Width - 4, FHeadH, 8, 8);
  cv.FillRect(Rect(4, FHeadH - 8, Width - 4, FHeadH));
  cv.Brush.Color := clWhite;
  cv.Alpha := 0.30;
  cv.FillRect(Rect(10, 5, Width - 10, 6));
  cv.Brush.Color := clBlack;
  cv.Alpha := 0.40;
  cv.FillRect(Rect(4, FHeadH - 1, Width - 4, FHeadH));
  cv.Alpha := 1;
  if FTitle <> '' then
  begin
    cv.Font.Color := headInk;
    cv.PushClip(Rect(8, 1, Width - 30, FHeadH));
    { centred in the title band, which runs from y = 4 (inside the frame) down to FHeadH }
    cv.TextOut(12, 4 + (FHeadH - 4 - cv.TextHeight(FTitle)) div 2, FTitle);
    cv.PopClip;
  end;
  cx := Width - 17;
  cy := (FHeadH + 4) div 2;
  cv.Brush.Color := arrow;
  if FCollapsed then
    cv.Polygon([Point(cx - 3, cy - 6), Point(cx - 3, cy + 6), Point(cx + 4, cy)])
  else
    cv.Polygon([Point(cx + 3, cy - 6), Point(cx + 3, cy + 6), Point(cx - 4, cy)]);
end;

{ TGLList }

{ the visible body ends 3 px above the control's bottom: that strip holds the drop shadow }
function TGLList.BodyH: Integer;
begin
  Result := Height - 3;
end;

constructor TGLList.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  FItems := TStringList.Create;
  TStringList(FItems).OnChange := ItemsChanged;
  FIndex := -1;
  FHoverIdx := -1;
  FItemHeight := 20;
  Width := 120;
  Height := 100;
  FAnim := TTimer.Create(Self);
  FAnim.Enabled := False;
  FAnim.Interval := 15;
  FAnim.OnTimer := AnimTick;
end;

procedure TGLList.Kick;
begin
  if (FAnim <> nil) and not (csDesigning in ComponentState) then FAnim.Enabled := True;
end;

{ the selection pill glides to the chosen row and the hover glow follows the mouse - the same
  easing as the menus and the list view; the timer only runs while something is moving (or the
  list has focus and its pill is breathing) }
procedure TGLList.AnimTick(Sender: TObject);
var
  moving: Boolean;
begin
  moving := False;
  if FIndex >= 0 then
  begin
    if FPillAlpha < 0.05 then FPillRow := FIndex;
    FPillRow := FPillRow + (FIndex - FPillRow) * 0.45;
    if Abs(FIndex - FPillRow) < 0.01 then FPillRow := FIndex else moving := True;
    if FPillAlpha < 1 then begin FPillAlpha := System.Math.Min(1, FPillAlpha + 0.25); moving := True; end;
  end
  else if FPillAlpha > 0 then
  begin
    FPillAlpha := System.Math.Max(0, FPillAlpha - 0.2);
    moving := True;
  end;
  if FHoverIdx >= 0 then
  begin
    if FHovAlpha < 0.05 then FHovRow := FHoverIdx;
    FHovRow := FHovRow + (FHoverIdx - FHovRow) * 0.5;
    if Abs(FHoverIdx - FHovRow) < 0.01 then FHovRow := FHoverIdx else moving := True;
    if FHovAlpha < 1 then begin FHovAlpha := System.Math.Min(1, FHovAlpha + 0.3); moving := True; end;
  end
  else if FHovAlpha > 0 then
  begin
    FHovAlpha := System.Math.Max(0, FHovAlpha - 0.25);
    moving := True;
  end;
  FPhase := FPhase + 0.11;
  if (not moving) and not (Focused and (FIndex >= 0)) then FAnim.Enabled := False;
  Invalidate;
end;

procedure TGLList.CMMouseLeave(var Msg: TMessage);
begin
  inherited;
  if FHoverIdx <> -1 then
  begin
    FHoverIdx := -1;
    Kick;
  end;
end;

destructor TGLList.Destroy;
begin
  TStringList(FItems).OnChange := nil;
  FItems.Free;
  inherited Destroy;
end;

procedure TGLList.WMGetDlgCode(var Msg: TWMGetDlgCode);
begin
  inherited;
  Msg.Result := Msg.Result or DLGC_WANTARROWS;
end;

procedure TGLList.Loaded;
begin
  inherited Loaded;
  FIndex := EnsureRange(FIndex, -1, FItems.Count - 1);
end;

function TGLList.GetCount: Integer;
begin
  Result := FItems.Count;
end;

function TGLList.GetSelected(AIndex: Integer): Boolean;
begin
  if FMultiSelect then
    Result := (AIndex >= 0) and (AIndex < Length(FPicked)) and FPicked[AIndex]
  else
    Result := AIndex = FIndex;
end;

procedure TGLList.SetSelected(AIndex: Integer; AValue: Boolean);
begin
  if (AIndex < 0) or (AIndex >= FItems.Count) then Exit;
  if FMultiSelect then
  begin
    if Length(FPicked) < FItems.Count then SetLength(FPicked, FItems.Count);
    FPicked[AIndex] := AValue;
    Invalidate;
  end
  else if AValue then SetIndex(AIndex);
end;

procedure TGLList.SetItems(AValue: TStrings);
begin
  FItems.Assign(AValue);
end;

procedure TGLList.ItemsChanged(Sender: TObject);
begin
  if Length(FPicked) <> FItems.Count then SetLength(FPicked, FItems.Count);
  if FIndex >= FItems.Count then FIndex := FItems.Count - 1;
  FContentW := -1;
  FTop := EnsureRange(FTop, 0, MaxTop);
  Invalidate;
end;

function TGLList.RowH: Integer;
begin
  Result := System.Math.Max(FItemHeight, Abs(Font.Height) + 8);
end;

function TGLList.VisibleRows: Integer;
begin
  Result := System.Math.Max(1, (BodyH - HBarH) div RowH);
end;

function TGLList.NeedHBar: Boolean;
var
  vbar: Integer;
begin
  if FItems.Count > System.Math.Max(1, BodyH div RowH) then vbar := 12 else vbar := 0;
  Result := (FContentW > 0) and (FContentW > Width - vbar);
end;

function TGLList.HBarH: Integer;
begin
  if NeedHBar then Result := 12 else Result := 0;
end;

function TGLList.MaxLeft: Integer;
var
  vbar: Integer;
begin
  if NeedBar then vbar := 12 else vbar := 0;
  Result := System.Math.Max(0, FContentW - (Width - vbar));
end;

function TGLList.HThumbRect: TRect;
var
  vbar, track, tw, tx: Integer;
begin
  if NeedBar then vbar := 12 else vbar := 0;
  track := Width - vbar;
  tw := System.Math.Max(20, Round(track * track / System.Math.Max(1, FContentW)));
  if MaxLeft > 0 then tx := Round((track - tw) * FLeft / MaxLeft) else tx := 0;
  Result := Rect(tx, BodyH - 10, tx + tw, BodyH - 2);
end;

procedure TGLList.SetLeft(AValue: Integer);
begin
  AValue := EnsureRange(AValue, 0, MaxLeft);
  if AValue = FLeft then Exit;
  FLeft := AValue;
  Invalidate;
end;

function TGLList.MaxTop: Integer;
begin
  Result := System.Math.Max(0, FItems.Count - VisibleRows);
end;

function TGLList.NeedBar: Boolean;
begin
  Result := FItems.Count > VisibleRows;
end;

function TGLList.ThumbRect: TRect;
var
  th, ty, track: Integer;
begin
  track := BodyH - HBarH;
  th := System.Math.Max(20, Round(track * VisibleRows / System.Math.Max(1, FItems.Count)));
  if MaxTop > 0 then ty := Round((track - th) * FTop / MaxTop) else ty := 0;
  Result := Rect(Width - 10, ty, Width - 2, ty + th);
end;

procedure TGLList.Resize;
begin
  inherited Resize;
  FTop := EnsureRange(FTop, 0, MaxTop);
  FLeft := EnsureRange(FLeft, 0, MaxLeft);
end;

procedure TGLList.SetTop(AValue: Integer);
begin
  AValue := EnsureRange(AValue, 0, MaxTop);
  if AValue = FTop then Exit;
  FTop := AValue;
  Invalidate;
end;

procedure TGLList.SetIndex(AValue: Integer);
begin
  if csLoading in ComponentState then
  begin
    FIndex := AValue;
    Exit;
  end;
  AValue := EnsureRange(AValue, -1, FItems.Count - 1);
  if AValue = FIndex then Exit;
  FIndex := AValue;
  if FIndex >= 0 then
  begin
    if FIndex < FTop then FTop := FIndex
    else if FIndex >= FTop + VisibleRows then FTop := FIndex - VisibleRows + 1;
  end;
  Invalidate;
end;

procedure TGLList.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  r: Integer;
  tr: TRect;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button <> mbLeft) or not Enabled then Exit;
  if NeedHBar and (Y >= BodyH - 12) and not (NeedBar and (X >= Width - 12)) then
  begin
    tr := HThumbRect;
    if (X >= tr.Left) and (X < tr.Right) then
    begin
      FHDragging := True;
      FHGrab := X - tr.Left;
    end
    else if X < tr.Left then SetLeft(FLeft - Width shr 1)
    else SetLeft(FLeft + Width shr 1);
    Exit;
  end;
  if NeedBar and (X >= Width - 12) and (Y < BodyH - HBarH) then
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
  r := FTop + Y div RowH;
  if (r >= 0) and (r < FItems.Count) then
  begin
    if FMultiSelect then SetSelected(r, not GetSelected(r));
    SetIndex(r);
    Click;
  end;
end;

procedure TGLList.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  room: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if FHDragging then
  begin
    room := Width - (HThumbRect.Right - HThumbRect.Left);
    if NeedBar then Dec(room, 12);
    if room > 0 then SetLeft(Round(MaxLeft * EnsureRange((X - FHGrab) / room, 0, 1)));
    Exit;
  end;
  if not FDragging then
  begin
    room := -1;
    if (Y < BodyH - HBarH) and not (NeedBar and (X >= Width - 12)) then
    begin
      room := FTop + Y div RowH;
      if room >= FItems.Count then room := -1;
    end;
    if room <> FHoverIdx then
    begin
      FHoverIdx := room;
      Kick;
    end;
    Exit;
  end;
  room := BodyH - HBarH - (ThumbRect.Bottom - ThumbRect.Top);
  if room > 0 then SetTop(Round(MaxTop * EnsureRange((Y - FGrab) / room, 0, 1)));
end;

procedure TGLList.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FDragging := False;
  FHDragging := False;
end;

function TGLList.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := True;
  if (ssShift in Shift) and NeedHBar then SetLeft(FLeft - Sign(WheelDelta) * 40)
  else SetTop(FTop - Sign(WheelDelta) * 3);
end;

procedure TGLList.KeyDown(var Key: Word; Shift: TShiftState);
var
  n: Integer;
begin
  inherited KeyDown(Key, Shift);
  case Key of
    VK_UP: n := FIndex - 1;
    VK_DOWN: n := FIndex + 1;
    VK_PRIOR: n := FIndex - VisibleRows;
    VK_NEXT: n := FIndex + VisibleRows;
    VK_HOME: n := 0;
    VK_END: n := FItems.Count - 1;
  else
    Exit;
  end;
  Key := 0;
  n := EnsureRange(n, 0, FItems.Count - 1);
  if (n <> FIndex) and (FItems.Count > 0) then
  begin
    SetIndex(n);
    Click;
  end;
end;

{ the floating selection pill of the lists: a soft shadow, a glow, a lit body with a bevel and a
  band of light that sweeps across it (as in the menus) }
procedure DrawSelectionPill(cv: TGLCanvas; const APill: TRect; AAccent: TColor; AAlpha, APhase: Double);
var
  deep: TColor;
  pulse: Double;
  k, sx: Integer;
begin
  deep := Blend(AAccent, clBlack, 0.62);   // a dark shade of the accent, so the white text reads clearly
  pulse := 0.5 + 0.5 * FastSin(APhase);
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := clBlack;
  cv.Alpha := 0.22 * AAlpha;
  cv.RoundRect(APill.Left - 1, APill.Top + 2, APill.Right + 3, APill.Bottom + 5, 12, 12);
  cv.Alpha := 0.34 * AAlpha;
  cv.RoundRect(APill.Left + 1, APill.Top + 2, APill.Right + 1, APill.Bottom + 3, 9, 9);
  cv.Brush.Color := AAccent;
  cv.Alpha := (0.10 + 0.16 * pulse) * AAlpha;
  cv.RoundRect(APill.Left - 2, APill.Top - 2, APill.Right + 2, APill.Bottom + 2, 11, 11);
  cv.Alpha := AAlpha;
  cv.Brush.Color := deep;
  cv.RoundRect(APill.Left, APill.Top, APill.Right, APill.Bottom, 8, 8);
  cv.Brush.Color := Blend(AAccent, clBlack, 0.46 - 0.10 * pulse);
  cv.RoundRect(APill.Left, APill.Top, APill.Right, APill.Bottom - 2, 8, 8);
  cv.Brush.Color := clWhite;
  cv.Alpha := 0.14 * AAlpha;
  cv.RoundRect(APill.Left + 2, APill.Top + 1, APill.Right - 2, APill.Top + (APill.Bottom - APill.Top) div 2, 6, 6);
  cv.PushClip(Rect(APill.Left + 1, APill.Top + 1, APill.Right - 1, APill.Bottom - 1));
  sx := APill.Left - 40 + Round(Frac(APhase / 8.0) * (APill.Right - APill.Left + 80));
  for k := 0 to 3 do
  begin
    cv.Alpha := (0.05 + 0.05 * k) * AAlpha;
    cv.Polygon([Point(sx + k * 5 + 8, APill.Top), Point(sx + 30 - k * 5 + 8, APill.Top),
      Point(sx + 30 - k * 5 - 4, APill.Bottom), Point(sx + k * 5 - 4, APill.Bottom)]);
  end;
  cv.PopClip;
  cv.Brush.Color := clWhite;
  cv.Alpha := 0.55 * AAlpha;
  cv.FillRect(Rect(APill.Left + 6, APill.Top + 1, APill.Right - 6, APill.Top + 2));
  cv.FillRect(Rect(APill.Left + 1, APill.Top + 6, APill.Left + 2, APill.Bottom - 6));
  cv.Brush.Color := clBlack;
  cv.Alpha := 0.5 * AAlpha;
  cv.FillRect(Rect(APill.Left + 6, APill.Bottom - 2, APill.Right - 6, APill.Bottom - 1));
  cv.FillRect(Rect(APill.Right - 2, APill.Top + 6, APill.Right - 1, APill.Bottom - 6));
  cv.Alpha := 1;
end;

procedure TGLList.PaintGL;
var
  cv: TGLCanvas;
  face, field: TColor;
  i, y, h, th, barW, hb, widest: Integer;
  tr: TRect;
begin
  cv := GL;
  face := FaceColor;
  field := FieldColor;
  h := RowH;
  if FContentW < 0 then
  begin
    widest := 0;
    for i := 0 to FItems.Count - 1 do
      widest := System.Math.Max(widest, 6 + cv.TextWidth(FItems[i]) + 8);
    FContentW := widest;
    FTop := EnsureRange(FTop, 0, MaxTop);
    FLeft := EnsureRange(FLeft, 0, MaxLeft);
  end;
  if NeedBar then barW := 12 else barW := 0;
  hb := HBarH;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := BackdropColor;
  cv.FillRect(Rect(0, 0, Width, Height));
  DrawDropShadow(cv, Rect(0, 0, Width, BodyH), 6, 3, 1.4);
  cv.Brush.Color := field;
  cv.FillRect(Rect(0, 0, Width, BodyH));
  th := cv.TextHeight('Ag');
  { keep the animation running until the pill has reached the selected row }
  if (FIndex >= 0) and ((FPillAlpha < 1) or (Abs(FIndex - FPillRow) > 0.01)) then Kick;
  cv.PushClip(Rect(0, 0, Width - barW, BodyH - hb));
  if FHovAlpha > 0.02 then
  begin
    cv.Brush.Color := HoverTint;
    cv.Alpha := 0.10 * FHovAlpha;
    cv.RoundRect(3, Round((FHovRow - FTop) * h) + 1, Width - barW - 3, Round((FHovRow - FTop) * h) + h - 1, 7, 7);
    cv.Alpha := 0.14 * FHovAlpha;
    cv.FillRect(Rect(8, Round((FHovRow - FTop) * h) + 1, Width - barW - 8, Round((FHovRow - FTop) * h) + 2));
    cv.Alpha := 1;
  end;
  if FMultiSelect then
  begin
    y := 0;
    for i := FTop to FItems.Count - 1 do
    begin
      if y >= BodyH - hb then Break;
      if GetSelected(i) and (i <> FIndex) then
      begin
        cv.Brush.Color := Blend(SelectionColor, clBlack, 0.50);   // dark shade: clear reading
        cv.FillRect(Rect(0, y, Width, y + h));
      end;
      Inc(y, h);
    end;
  end;
  if FPillAlpha > 0.02 then
  begin
    y := Round((FPillRow - FTop) * h);
    DrawSelectionPill(cv, Rect(3, y + 1, Width - barW - 3, y + h - 1), SelectionColor, FPillAlpha, FPhase);
  end;
  cv.PopClip;
  y := 0;
  for i := FTop to FItems.Count - 1 do
  begin
    if y >= BodyH - hb then Break;
    if GetSelected(i) or ((i = FIndex) and (FPillAlpha > 0.5)) then cv.Font.Color := SelectionTextColor
    else cv.Font.Color := Sys(clWindowText);
    cv.PushClip(Rect(0, y, Width - barW, System.Math.Min(y + h, BodyH - hb)));
    cv.TextOut(6 - FLeft, y + (h - th) div 2, FItems[i]);
    cv.PopClip;
    Inc(y, h);
  end;
  DrawInsetShadow(cv, Rect(0, 0, Width - barW, BodyH - hb), 4);
  if NeedBar then
  begin
    tr := ThumbRect;
    cv.Brush.Color := Blend(field, InkColor, 0.12);
    cv.FillRect(Rect(Width - 12, 0, Width, BodyH - hb));
    GLDrawScrollThumb(cv, Self, 0, tr, True, FDragging, Hover, field, InkColor, AccentColor);
  end;
  if hb > 0 then
  begin
    tr := HThumbRect;
    cv.Brush.Color := Blend(field, InkColor, 0.12);
    cv.FillRect(Rect(0, BodyH - 12, Width, BodyH));
    GLDrawScrollThumb(cv, Self, 1, tr, False, FHDragging, Hover, field, InkColor, AccentColor);
  end;
  cv.Pen.Style := psSolid;
  if Focused then cv.Pen.Color := FocusColor else cv.Pen.Color := Blend(face, InkColor, 0.25);
  cv.Brush.Style := bsClear;
  cv.Rectangle(0, 0, Width, BodyH);
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
end;

{ TGLMemo }

constructor TGLMemo.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  FReadOnly := True;
  FPlainText := True;
  FWordWrap := True;
  FPrefX := -1;
  FLines := TStringList.Create;
  TStringList(FLines).OnChange := LinesChanged;
  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := GetCaretBlinkTime;
  FTimer.OnTimer := Blink;
  FMeasure := TBitmap.Create;
  FMeasure.SetSize(8, 8);
  FSelA.Line := -1;
  FSelC.Line := -1;
  Width := 185;
  Height := 89;
end;

destructor TGLMemo.Destroy;
begin
  FTimer.Free;
  TStringList(FLines).OnChange := nil;
  FMeasure.Free;
  FLines.Free;
  inherited Destroy;
end;

procedure TGLMemo.WMGetDlgCode(var Msg: TWMGetDlgCode);
begin
  inherited;
  Msg.Result := Msg.Result or DLGC_WANTARROWS;
  if not FReadOnly then Msg.Result := Msg.Result or DLGC_WANTALLKEYS or DLGC_WANTCHARS;
end;

procedure TGLMemo.SetLines(AValue: TStrings);
begin
  FLines.Assign(AValue);
end;

procedure TGLMemo.SetScrollBars(AValue: System.UITypes.TScrollStyle);
begin
  FScrollBars := AValue;
  FRowsValid := False;
  Invalidate;
end;

procedure TGLMemo.SetWordWrap(AValue: Boolean);
begin
  FWordWrap := AValue;
  FRowsValid := False;
  Invalidate;
end;

{ no trailing line break, like TMemo / TRichEdit.Text }
function TGLMemo.GetText: string;
begin
  Result := FLines.Text;
  if (Length(Result) >= Length(sLineBreak)) and
     (Copy(Result, Length(Result) - Length(sLineBreak) + 1, Length(sLineBreak)) = sLineBreak) then
    SetLength(Result, Length(Result) - Length(sLineBreak));
end;

procedure TGLMemo.SetText(const AValue: string);
begin
  FSelA.Line := -1;
  FSelC.Line := -1;
  FLines.Text := AValue;
end;

procedure TGLMemo.Clear;
begin
  FSelA.Line := -1;
  FSelC.Line := -1;
  FLines.Clear;
end;

procedure TGLMemo.LinesChanged(Sender: TObject);
begin
  FRowsValid := False;
  if (FSelA.Line >= FLines.Count) or (FSelC.Line >= FLines.Count) then
  begin
    FSelA.Line := -1;
    FSelC.Line := -1;
  end;
  Invalidate;
  if Assigned(FOnChange) and not FInChange then
  begin
    FInChange := True;
    try
      FOnChange(Self);
    finally
      FInChange := False;
    end;
  end;
end;

procedure TGLMemo.Resize;
begin
  inherited Resize;
  FRowsValid := False;
end;

procedure TGLMemo.PrepMeasure;
begin
  FMeasure.Canvas.Font.Assign(Font);
end;

function TGLMemo.LineH: Integer;
begin
  PrepMeasure;
  Result := FMeasure.Canvas.TextHeight('Ag') + 1;
end;

function TGLMemo.ShowV: Boolean;
begin
  Result := (FScrollBars in [System.UITypes.TScrollStyle.ssVertical, System.UITypes.TScrollStyle.ssBoth]) and (Length(FRows) * LineH > Height - 8);
end;

function TGLMemo.ShowH: Boolean;
begin
  Result := (FScrollBars in [System.UITypes.TScrollStyle.ssHorizontal, System.UITypes.TScrollStyle.ssBoth]) and not FWordWrap and (FMaxPx > Width - 8);
end;

function TGLMemo.ViewW: Integer;
begin
  Result := Width - 8;
  if (FScrollBars in [System.UITypes.TScrollStyle.ssVertical, System.UITypes.TScrollStyle.ssBoth]) and (Length(FRows) * LineH > Height - 8) then Dec(Result, 12);
end;

function TGLMemo.ViewH: Integer;
begin
  Result := Height - 8;
  if ShowH then Dec(Result, 12);
end;

{ greedy word wrap of one logical line into rows no wider than AWidth }
procedure TGLMemo.WrapLine(ALine, AWidth: Integer; var ARows: TArray<TGLMemoRow>; var ACount: Integer);
var
  t: string;
  start, lo, hi, mid, e, k: Integer;
  r: TGLMemoRow;
  procedure Add(AStart, ALen: Integer);
  begin
    if ACount >= Length(ARows) then SetLength(ARows, System.Math.Max(64, Length(ARows) * 2));
    r.Line := ALine;
    r.Start := AStart;
    r.Len := ALen;
    ARows[ACount] := r;
    Inc(ACount);
  end;
begin
  t := FLines[ALine];
  if (t = '') or (FMeasure.Canvas.TextWidth(t) <= AWidth) then
  begin
    Add(0, Length(t));
    Exit;
  end;
  start := 0;
  while start < Length(t) do
  begin
    if FMeasure.Canvas.TextWidth(Copy(t, start + 1, MaxInt)) <= AWidth then
    begin
      Add(start, Length(t) - start);
      Break;
    end;
    lo := 1;
    hi := Length(t) - start;
    while lo < hi do
    begin
      mid := (lo + hi + 1) div 2;
      if FMeasure.Canvas.TextWidth(Copy(t, start + 1, mid)) <= AWidth then lo := mid else hi := mid - 1;
    end;
    e := lo;
    { prefer breaking after the last space inside the fitting span }
    k := e;
    while (k > 1) and (t[start + k] <> ' ') do Dec(k);
    if (k > 1) and (start + e < Length(t)) then e := k;
    Add(start, e);
    Inc(start, e);
  end;
end;

procedure TGLMemo.EnsureLayout;
var
  i, n, w, widest, wi: Integer;
  rows: TArray<TGLMemoRow>;
  pass: Integer;
begin
  if FRowsValid and (FLayoutW = Width) then Exit;
  PrepMeasure;
  FMaxPx := 0;
  for pass := 0 to 1 do
  begin
    w := Width - 8;
    if (FScrollBars in [System.UITypes.TScrollStyle.ssVertical, System.UITypes.TScrollStyle.ssBoth]) and (pass = 1) then Dec(w, 12);
    n := 0;
    SetLength(rows, 0);
    if FWordWrap then
      for i := 0 to FLines.Count - 1 do WrapLine(i, w, rows, n)
    else
    begin
      SetLength(rows, FLines.Count);
      widest := 0;
      wi := 0;
      for i := 0 to FLines.Count - 1 do
      begin
        rows[i].Line := i;
        rows[i].Start := 0;
        rows[i].Len := Length(FLines[i]);
        if Length(FLines[i]) > widest then
        begin
          widest := Length(FLines[i]);
          wi := i;
        end;
      end;
      n := FLines.Count;
      if FLines.Count > 0 then FMaxPx := FMeasure.Canvas.TextWidth(FLines[wi]);
    end;
    SetLength(rows, n);
    FRows := rows;
    { a vertical bar takes width: if it appears, wrap once more at the narrower width }
    if not FWordWrap or (pass = 1) or not (FScrollBars in [System.UITypes.TScrollStyle.ssVertical, System.UITypes.TScrollStyle.ssBoth]) then Break;
    if n * (FMeasure.Canvas.TextHeight('Ag') + 1) <= Height - 8 then Break;
  end;
  FRowsValid := True;
  FLayoutW := Width;
  ClampScroll;
end;

function TGLMemo.MaxTopRow: Integer;
begin
  Result := System.Math.Max(0, Length(FRows) - System.Math.Max(1, ViewH div LineH));
end;

function TGLMemo.MaxLeftPx: Integer;
begin
  if FWordWrap then Result := 0
  else Result := System.Math.Max(0, FMaxPx - ViewW + 4);
end;

procedure TGLMemo.ClampScroll;
begin
  FTopRow := EnsureRange(FTopRow, 0, MaxTopRow);
  FLeftPx := EnsureRange(FLeftPx, 0, MaxLeftPx);
end;

procedure TGLMemo.ScrollToEnd;
begin
  EnsureLayout;
  FTopRow := MaxTopRow;
  Invalidate;
end;

function TGLMemo.RowText(const R: TGLMemoRow): string;
begin
  Result := Copy(FLines[R.Line], R.Start + 1, R.Len);
end;

function TGLMemo.PosLess(const A, B: TGLTextPos): Boolean;
begin
  Result := (A.Line < B.Line) or ((A.Line = B.Line) and (A.Col < B.Col));
end;

function TGLMemo.HasSel: Boolean;
begin
  Result := (FSelA.Line >= 0) and (FSelC.Line >= 0) and
    ((FSelA.Line <> FSelC.Line) or (FSelA.Col <> FSelC.Col));
end;

function TGLMemo.SelectedText: string;
var
  a, b: TGLTextPos;
  i: Integer;
  t: string;
begin
  Result := '';
  if not HasSel then Exit;
  if PosLess(FSelC, FSelA) then
  begin
    a := FSelC;
    b := FSelA;
  end
  else
  begin
    a := FSelA;
    b := FSelC;
  end;
  for i := a.Line to b.Line do
  begin
    t := FLines[i];
    if i = b.Line then t := Copy(t, 1, b.Col);
    if i = a.Line then t := Copy(t, a.Col + 1, MaxInt);
    if i > a.Line then Result := Result + sLineBreak;
    Result := Result + t;
  end;
end;

procedure TGLMemo.SelectAll;
begin
  if FLines.Count = 0 then Exit;
  FSelA.Line := 0;
  FSelA.Col := 0;
  FSelC.Line := FLines.Count - 1;
  FSelC.Col := Length(FLines[FLines.Count - 1]);
  Invalidate;
end;

procedure TGLMemo.CopyToClipboard;
var
  s: string;
begin
  s := SelectedText;
  if (s = '') and FReadOnly then s := FLines.Text;
  if s <> '' then Clipboard.AsText := s;
end;

function TGLMemo.PosAt(X, Y: Integer): TGLTextPos;
var
  r, lo, hi, mid, px: Integer;
  t: string;
begin
  EnsureLayout;
  Result.Line := 0;
  Result.Col := 0;
  if Length(FRows) = 0 then Exit;
  r := EnsureRange(FTopRow + (Y - 4) div LineH, 0, Length(FRows) - 1);
  t := RowText(FRows[r]);
  px := X - 4 + FLeftPx;
  PrepMeasure;
  lo := 0;
  hi := Length(t);
  while lo < hi do
  begin
    mid := (lo + hi + 1) div 2;
    if FMeasure.Canvas.TextWidth(Copy(t, 1, mid)) <= px then lo := mid else hi := mid - 1;
  end;
  { nearest character edge }
  if (lo < Length(t)) and
     (px - FMeasure.Canvas.TextWidth(Copy(t, 1, lo)) >
      FMeasure.Canvas.TextWidth(Copy(t, 1, lo + 1)) - px) then Inc(lo);
  Result.Line := FRows[r].Line;
  Result.Col := FRows[r].Start + lo;
end;

function TGLMemo.VThumb: TRect;
var
  total, th, ty, trackH: Integer;
begin
  trackH := ViewH;
  total := System.Math.Max(1, Length(FRows));
  th := System.Math.Max(20, Round(trackH * System.Math.Min(1, (ViewH div LineH) / total)));
  if MaxTopRow > 0 then ty := Round((trackH - th) * FTopRow / MaxTopRow) else ty := 0;
  Result := Rect(Width - 11, ty + 1, Width - 3, ty + th - 1);
end;

function TGLMemo.HThumb: TRect;
var
  tw, tx, trackW: Integer;
begin
  trackW := ViewW + 4;
  tw := System.Math.Max(20, Round(trackW * System.Math.Min(1, ViewW / System.Math.Max(1, FMaxPx))));
  if MaxLeftPx > 0 then tx := Round((trackW - tw) * FLeftPx / MaxLeftPx) else tx := 0;
  Result := Rect(tx + 1, Height - 11, tx + tw - 1, Height - 3);
end;

procedure TGLMemo.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  tr: TRect;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button <> mbLeft) or not Enabled then Exit;
  EnsureLayout;
  if ShowV and (X >= Width - 12) then
  begin
    tr := VThumb;
    if (Y >= tr.Top) and (Y < tr.Bottom) then
    begin
      FDragV := True;
      FGrab := Y - tr.Top;
    end
    else begin
      FTopRow := FTopRow + Sign(Y - tr.Top) * System.Math.Max(1, ViewH div LineH - 1);
      ClampScroll;
      Invalidate;
    end;
    Exit;
  end;
  if ShowH and (Y >= Height - 12) then
  begin
    tr := HThumb;
    if (X >= tr.Left) and (X < tr.Right) then
    begin
      FDragH := True;
      FGrab := X - tr.Left;
    end
    else begin
      FLeftPx := FLeftPx + Sign(X - tr.Left) * ViewW;
      ClampScroll;
      Invalidate;
    end;
    Exit;
  end;
  if (ssShift in Shift) and (FSelA.Line >= 0) then FSelC := PosAt(X, Y)
  else
  begin
    FSelA := PosAt(X, Y);
    FSelC := FSelA;
  end;
  FPrefX := -1;
  FCaretOn := True;
  FSelecting := True;
  Invalidate;
end;

procedure TGLMemo.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  room: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if FDragV then
  begin
    room := ViewH - (VThumb.Bottom - VThumb.Top + 2);
    if room > 0 then FTopRow := Round(MaxTopRow * EnsureRange((Y - FGrab) / room, 0, 1));
    Invalidate;
  end
  else if FDragH then
  begin
    room := ViewW + 4 - (HThumb.Right - HThumb.Left + 2);
    if room > 0 then FLeftPx := Round(MaxLeftPx * EnsureRange((X - FGrab) / room, 0, 1));
    Invalidate;
  end
  else if FSelecting then
  begin
    if Y < 4 then Dec(FTopRow)
    else if Y > Height - 4 then Inc(FTopRow);
    ClampScroll;
    FSelC := PosAt(X, Y);
    Invalidate;
  end;
end;

procedure TGLMemo.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FDragV := False;
  FDragH := False;
  FSelecting := False;
end;

function TGLMemo.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := True;
  EnsureLayout;
  FTopRow := FTopRow - Sign(WheelDelta) * 3;
  ClampScroll;
  Invalidate;
end;

procedure TGLMemo.KeyDown(var Key: Word; Shift: TShiftState);
var
  page: Integer;
begin
  inherited KeyDown(Key, Shift);
  EnsureLayout;
  if not FReadOnly then
  begin
    EditKey(Key, Shift);
    Exit;
  end;
  page := System.Math.Max(1, ViewH div LineH - 1);
  case Key of
    VK_UP: Dec(FTopRow);
    VK_DOWN: Inc(FTopRow);
    VK_PRIOR: Dec(FTopRow, page);
    VK_NEXT: Inc(FTopRow, page);
    VK_LEFT: Dec(FLeftPx, 24);
    VK_RIGHT: Inc(FLeftPx, 24);
    VK_HOME: if ssCtrl in Shift then FTopRow := 0 else FLeftPx := 0;
    VK_END: if ssCtrl in Shift then FTopRow := MaxTopRow;
  else
    if ssCtrl in Shift then
    begin
      if Key = Ord('A') then SelectAll
      else if (Key = Ord('C')) or (Key = VK_INSERT) then CopyToClipboard
      else Exit;
      Key := 0;
    end;
    Exit;
  end;
  Key := 0;
  ClampScroll;
  Invalidate;
end;

procedure TGLMemo.PaintGL;
var
  cv: TGLCanvas;
  face, field: TColor;
  lh, i, y, viewBottom, x0, a, b, sx, ex: Integer;
  r: TGLMemoRow;
  t: string;
  sa, sc: TGLTextPos;
  tr: TRect;
begin
  EnsureLayout;
  cv := GL;
  face := FaceColor;
  field := FieldColor;
  lh := LineH;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := field;
  cv.FillRect(Rect(0, 0, Width, Height));
  if PosLess(FSelC, FSelA) then
  begin
    sa := FSelC;
    sc := FSelA;
  end
  else
  begin
    sa := FSelA;
    sc := FSelC;
  end;
  viewBottom := ViewH + 4;
  cv.PushClip(Rect(4, 4, ViewW + 4, viewBottom));
  y := 4;
  x0 := 4 - FLeftPx;
  cv.Font.Color := Sys(clWindowText);
  for i := FTopRow to Length(FRows) - 1 do
  begin
    if y >= viewBottom then Break;
    r := FRows[i];
    t := RowText(r);
    if HasSel and (r.Line >= sa.Line) and (r.Line <= sc.Line) then
    begin
      a := 0;
      b := Length(t);
      if r.Line = sa.Line then a := EnsureRange(sa.Col - r.Start, 0, Length(t));
      if r.Line = sc.Line then b := EnsureRange(sc.Col - r.Start, 0, Length(t));
      if b > a then
      begin
        sx := x0 + cv.TextWidth(Copy(t, 1, a));
        ex := x0 + cv.TextWidth(Copy(t, 1, b));
        if (r.Line < sc.Line) and (b = Length(t)) and (r.Start + r.Len >= Length(FLines[r.Line])) then
          Inc(ex, 6);
        cv.Brush.Color := AccentColor;
        cv.FillRect(Rect(sx, y, ex, y + lh));
        cv.Font.Color := Sys(clHighlightText);
        cv.TextOut(x0, y, t);
        cv.Font.Color := Sys(clWindowText);
      end;
    end;
    cv.TextOut(x0, y, t);
    if (not FReadOnly) and Focused and FCaretOn and (not HasSel) and (FSelC.Line >= 0) and
       (i = CaretRow) then
    begin
      cv.Brush.Color := Sys(clWindowText);
      cv.FillRect(Rect(CaretPixelX, y, CaretPixelX + 1, y + lh));
    end;
    Inc(y, lh);
  end;
  cv.PopClip;
  if ShowV then
  begin
    tr := VThumb;
    cv.Brush.Color := Blend(field, InkColor, 0.1);
    cv.FillRect(Rect(Width - 12, 0, Width, Height));
    GLDrawScrollThumb(cv, Self, 0, tr, True, FDragV, Hover, field, InkColor, AccentColor);
  end;
  if ShowH then
  begin
    tr := HThumb;
    cv.Brush.Color := Blend(field, InkColor, 0.1);
    cv.FillRect(Rect(0, Height - 12, Width, Height));
    GLDrawScrollThumb(cv, Self, 1, tr, False, FDragH, Hover, field, InkColor, AccentColor);
  end;
  cv.Pen.Style := psSolid;
  if Focused then cv.Pen.Color := FocusColor else cv.Pen.Color := Blend(face, InkColor, 0.25);
  cv.Brush.Style := bsClear;
  cv.Rectangle(0, 0, Width, Height);
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
end;


{ ---- TGLMemo editing ---- }

procedure TGLMemo.WMSetFocus(var Msg: TWMSetFocus);
begin
  inherited;
  if not FReadOnly then
  begin
    FCaretOn := True;
    FTimer.Enabled := True;
  end;
  Invalidate;
end;

procedure TGLMemo.WMKillFocus(var Msg: TWMKillFocus);
begin
  inherited;
  FTimer.Enabled := False;
  FCaretOn := False;
  Invalidate;
end;

procedure TGLMemo.Blink(Sender: TObject);
begin
  FCaretOn := not FCaretOn;
  Invalidate;
end;

function TGLMemo.PosToOffset(const P: TGLTextPos): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to System.Math.Min(P.Line, FLines.Count) - 1 do
    Inc(Result, Length(FLines[i]) + Length(sLineBreak));
  if P.Line < FLines.Count then Inc(Result, System.Math.Min(P.Col, Length(FLines[P.Line])));
end;

function TGLMemo.OffsetToPos(AOffset: Integer): TGLTextPos;
var
  i, n: Integer;
begin
  Result.Line := 0;
  Result.Col := 0;
  if FLines.Count = 0 then Exit;
  for i := 0 to FLines.Count - 1 do
  begin
    n := Length(FLines[i]);
    if AOffset <= n then
    begin
      Result.Line := i;
      Result.Col := System.Math.Max(0, AOffset);
      Exit;
    end;
    Dec(AOffset, n + Length(sLineBreak));
  end;
  Result.Line := FLines.Count - 1;
  Result.Col := Length(FLines[Result.Line]);
end;

function TGLMemo.GetSelStart: Integer;
var
  a: TGLTextPos;
begin
  if FSelC.Line < 0 then Exit(0);
  if PosLess(FSelC, FSelA) then a := FSelC else a := FSelA;
  Result := PosToOffset(a);
end;

procedure TGLMemo.SetSelStart(AValue: Integer);
begin
  FSelA := OffsetToPos(AValue);
  FSelC := FSelA;
  Invalidate;
end;

function TGLMemo.GetSelLength: Integer;
begin
  if FSelC.Line < 0 then Exit(0);
  Result := Abs(PosToOffset(FSelC) - PosToOffset(FSelA));
end;

procedure TGLMemo.SetSelLength(AValue: Integer);
begin
  if FSelA.Line < 0 then
  begin
    FSelA.Line := 0;
    FSelA.Col := 0;
  end;
  FSelC := OffsetToPos(PosToOffset(FSelA) + AValue);
  Invalidate;
end;

function TGLMemo.GetSelText: string;
begin
  Result := SelectedText;
end;

procedure TGLMemo.SetSelText(const AValue: string);
begin
  ReplaceSel(AValue);
end;

procedure TGLMemo.PushUndo;
begin
  if Length(FUndoText) >= 200 then
  begin
    Move(FUndoText[1], FUndoText[0], 0);
    FUndoText := Copy(FUndoText, 1, MaxInt);
    FUndoSel := Copy(FUndoSel, 1, MaxInt);
  end;
  SetLength(FUndoText, Length(FUndoText) + 1);
  SetLength(FUndoSel, Length(FUndoSel) + 1);
  FUndoText[High(FUndoText)] := FLines.Text;
  FUndoSel[High(FUndoSel)] := GetSelStart + GetSelLength;
end;

procedure TGLMemo.DoUndo;
var
  n: Integer;
begin
  n := High(FUndoText);
  if n < 0 then Exit;
  FLines.Text := FUndoText[n];
  FSelA := OffsetToPos(FUndoSel[n]);
  FSelC := FSelA;
  SetLength(FUndoText, n);
  SetLength(FUndoSel, n);
  EnsureLayout;
  EnsureCaretVisible;
end;

{ replaces the selection (or inserts at the caret) with S; S may hold line breaks }
procedure TGLMemo.ReplaceSel(const S: string);
var
  a, b, np: TGLTextPos;
  head, tail, txt, work: string;
  parts: TStringList;
  i, start, room, breaks, lastBreakEnd: Integer;
begin
  txt := S;
  if FSelC.Line < 0 then
  begin
    FSelA.Line := 0;
    FSelA.Col := 0;
    FSelC := FSelA;
  end;
  if FLines.Count = 0 then FLines.Add('');
  if PosLess(FSelC, FSelA) then
  begin
    a := FSelC;
    b := FSelA;
  end
  else
  begin
    a := FSelA;
    b := FSelC;
  end;
  if FMaxLength > 0 then
  begin
    room := FMaxLength - (Length(GetText) - (PosToOffset(b) - PosToOffset(a)));
    if room < 0 then room := 0;
    if Length(txt) > room then txt := Copy(txt, 1, room);
  end;
  if (txt = '') and (a.Line = b.Line) and (a.Col = b.Col) then Exit;
  PushUndo;
  head := Copy(FLines[a.Line], 1, a.Col);
  tail := Copy(FLines[b.Line], b.Col + 1, MaxInt);
  work := head + txt + tail;
  { split on CRLF / CR / LF, keeping a final empty line }
  parts := TStringList.Create;
  try
    start := 1;
    i := 1;
    while i <= Length(work) do
    begin
      if (work[i] = #13) or (work[i] = #10) then
      begin
        parts.Add(Copy(work, start, i - start));
        if (work[i] = #13) and (i < Length(work)) and (work[i + 1] = #10) then Inc(i);
        start := i + 1;
      end;
      Inc(i);
    end;
    parts.Add(Copy(work, start, MaxInt));
    FLines.BeginUpdate;
    try
      for i := b.Line downto a.Line do FLines.Delete(i);
      for i := 0 to parts.Count - 1 do FLines.Insert(a.Line + i, parts[i]);
      { caret after the inserted text }
      breaks := 0;
      lastBreakEnd := 0;
      i := 1;
      while i <= Length(txt) do
      begin
        if (txt[i] = #13) or (txt[i] = #10) then
        begin
          Inc(breaks);
          if (txt[i] = #13) and (i < Length(txt)) and (txt[i + 1] = #10) then Inc(i);
          lastBreakEnd := i;
        end;
        Inc(i);
      end;
      if breaks = 0 then
      begin
        np.Line := a.Line;
        np.Col := a.Col + Length(txt);
      end
      else
      begin
        np.Line := a.Line + breaks;
        np.Col := Length(txt) - lastBreakEnd;
      end;
      FSelA := np;
      FSelC := np;
    finally
      FLines.EndUpdate;
    end;
  finally
    parts.Free;
  end;
  FPrefX := -1;
  FCaretOn := True;
  EnsureLayout;
  EnsureCaretVisible;
end;

function TGLMemo.CaretRow: Integer;
var
  i: Integer;
  r: TGLMemoRow;
  lastOfLine: Boolean;
begin
  EnsureLayout;
  Result := 0;
  if FSelC.Line < 0 then Exit;
  for i := 0 to High(FRows) do
  begin
    r := FRows[i];
    if r.Line <> FSelC.Line then Continue;
    lastOfLine := (i = High(FRows)) or (FRows[i + 1].Line <> r.Line);
    if (FSelC.Col < r.Start + r.Len) or lastOfLine then
      if FSelC.Col >= r.Start then Exit(i);
  end;
end;

function TGLMemo.CaretPixelX: Integer;
var
  r: TGLMemoRow;
  ri: Integer;
begin
  EnsureLayout;
  PrepMeasure;
  ri := CaretRow;
  if (ri < 0) or (ri > High(FRows)) then Exit(4);
  r := FRows[ri];
  Result := 4 - FLeftPx + FMeasure.Canvas.TextWidth(Copy(FLines[r.Line], r.Start + 1, FSelC.Col - r.Start));
end;

function TGLMemo.ColAtRowX(ARow, AX: Integer): Integer;
var
  t: string;
  lo, hi, mid: Integer;
begin
  Result := 0;
  if (ARow < 0) or (ARow > High(FRows)) then Exit;
  t := RowText(FRows[ARow]);
  PrepMeasure;
  lo := 0;
  hi := Length(t);
  while lo < hi do
  begin
    mid := (lo + hi + 1) div 2;
    if FMeasure.Canvas.TextWidth(Copy(t, 1, mid)) <= AX then lo := mid else hi := mid - 1;
  end;
  if (lo < Length(t)) and
     (AX - FMeasure.Canvas.TextWidth(Copy(t, 1, lo)) > FMeasure.Canvas.TextWidth(Copy(t, 1, lo + 1)) - AX) then
    Inc(lo);
  Result := FRows[ARow].Start + lo;
end;

procedure TGLMemo.EnsureCaretVisible;
var
  ri, vis, cx: Integer;
begin
  EnsureLayout;
  ri := CaretRow;
  vis := System.Math.Max(1, ViewH div LineH);
  if ri < FTopRow then FTopRow := ri
  else if ri >= FTopRow + vis then FTopRow := ri - vis + 1;
  if not FWordWrap then
  begin
    cx := CaretPixelX + FLeftPx;
    if cx - FLeftPx < 4 then FLeftPx := System.Math.Max(0, cx - 4)
    else if cx - FLeftPx > ViewW then FLeftPx := cx - ViewW + 8;
  end;
  ClampScroll;
  Invalidate;
end;

procedure TGLMemo.MoveCaret(const P: TGLTextPos; AExtend: Boolean);
begin
  FSelC := P;
  if not AExtend then FSelA := P;
  FCaretOn := True;
  EnsureCaretVisible;
end;

procedure TGLMemo.EditKey(var Key: Word; Shift: TShiftState);
var
  p: TGLTextPos;
  ri, page, x: Integer;
  ext: Boolean;
  r: TGLMemoRow;
  keep: Boolean;
begin
  ext := ssShift in Shift;
  page := System.Math.Max(1, ViewH div LineH - 1);
  if FSelC.Line < 0 then
  begin
    FSelA.Line := 0;
    FSelA.Col := 0;
    FSelC := FSelA;
  end;
  keep := False;   { vertical moves keep the preferred column }
  p := FSelC;
  case Key of
    VK_LEFT:
      begin
        if HasSel and not ext then
        begin
          if PosLess(FSelC, FSelA) then p := FSelC else p := FSelA;
        end
        else if p.Col > 0 then Dec(p.Col)
        else if p.Line > 0 then
        begin
          Dec(p.Line);
          p.Col := Length(FLines[p.Line]);
        end;
        MoveCaret(p, ext);
      end;
    VK_RIGHT:
      begin
        if HasSel and not ext then
        begin
          if PosLess(FSelC, FSelA) then p := FSelA else p := FSelC;
        end
        else if (FLines.Count > 0) and (p.Col < Length(FLines[p.Line])) then Inc(p.Col)
        else if p.Line < FLines.Count - 1 then
        begin
          Inc(p.Line);
          p.Col := 0;
        end;
        MoveCaret(p, ext);
      end;
    VK_UP, VK_DOWN, VK_PRIOR, VK_NEXT:
      begin
        ri := CaretRow;
        if FPrefX < 0 then FPrefX := CaretPixelX + FLeftPx - 4;
        case Key of
          VK_UP: Dec(ri);
          VK_DOWN: Inc(ri);
          VK_PRIOR: Dec(ri, page);
          VK_NEXT: Inc(ri, page);
        end;
        ri := EnsureRange(ri, 0, System.Math.Max(0, High(FRows)));
        if Length(FRows) > 0 then
        begin
          p.Line := FRows[ri].Line;
          p.Col := ColAtRowX(ri, FPrefX);
        end;
        x := FPrefX;
        MoveCaret(p, ext);
        FPrefX := x;
        keep := True;
      end;
    VK_HOME:
      begin
        if ssCtrl in Shift then
        begin
          p.Line := 0;
          p.Col := 0;
        end
        else if Length(FRows) > 0 then
        begin
          r := FRows[CaretRow];
          p.Col := r.Start;
        end;
        MoveCaret(p, ext);
      end;
    VK_END:
      begin
        if ssCtrl in Shift then
        begin
          p.Line := System.Math.Max(0, FLines.Count - 1);
          if FLines.Count > 0 then p.Col := Length(FLines[p.Line]) else p.Col := 0;
        end
        else if Length(FRows) > 0 then
        begin
          r := FRows[CaretRow];
          p.Col := r.Start + r.Len;
        end;
        MoveCaret(p, ext);
      end;
    VK_BACK:
      begin
        if not HasSel then
        begin
          if (FSelC.Col > 0) then FSelA.Col := FSelC.Col - 1
          else if FSelC.Line > 0 then
          begin
            FSelA.Line := FSelC.Line - 1;
            FSelA.Col := Length(FLines[FSelA.Line]);
          end;
          if not HasSel then
          begin
            Key := 0;
            Exit;
          end;
        end;
        ReplaceSel('');
      end;
    VK_DELETE:
      begin
        if ssShift in Shift then CutToClipboard
        else
        begin
          if not HasSel then
          begin
            if (FLines.Count > 0) and (FSelC.Col < Length(FLines[FSelC.Line])) then FSelA.Col := FSelC.Col + 1
            else if FSelC.Line < FLines.Count - 1 then
            begin
              FSelA.Line := FSelC.Line + 1;
              FSelA.Col := 0;
            end;
            if not HasSel then
            begin
              Key := 0;
              Exit;
            end;
          end;
          ReplaceSel('');
        end;
      end;
    VK_TAB:
      begin
        { Tab leaves the box (the dialog code is claimed for Enter) }
        if GetParentForm(Self) <> nil then
          TWinAccess(GetParentForm(Self)).SelectNext(Self, not (ssShift in Shift), True);
      end;
    VK_INSERT:
      if ssCtrl in Shift then CopyToClipboard
      else if ssShift in Shift then PasteFromClipboard
      else Exit;
  else
    if ssCtrl in Shift then
    begin
      case Key of
        Ord('A'): SelectAll;
        Ord('C'): CopyToClipboard;
        Ord('X'): CutToClipboard;
        Ord('V'): PasteFromClipboard;
        Ord('Z'): DoUndo;
      else
        Exit;
      end;
    end
    else Exit;
  end;
  if not keep then FPrefX := -1;
  Key := 0;
end;

procedure TGLMemo.KeyPress(var Key: Char);
begin
  inherited KeyPress(Key);
  if FReadOnly then Exit;
  if Key = #13 then ReplaceSel(sLineBreak)
  else if Key >= #32 then ReplaceSel(Key);
  Key := #0;
end;

procedure TGLMemo.CutToClipboard;
var
  t: string;
begin
  t := SelectedText;
  if t = '' then Exit;
  Clipboard.AsText := t;
  if not FReadOnly then ReplaceSel('');
end;

procedure TGLMemo.PasteFromClipboard;
begin
  if FReadOnly then Exit;
  if Clipboard.HasFormat(CF_UNICODETEXT) then ReplaceSel(Clipboard.AsText);
end;

{ TGLColumn }

constructor TGLColumn.Create(ACollection: TCollection);
begin
  inherited Create(ACollection);
  FWidth := 100;
end;

procedure TGLColumn.Assign(ASource: TPersistent);
begin
  if ASource is TGLColumn then
  begin
    FCaption := TGLColumn(ASource).FCaption;
    FWidth := TGLColumn(ASource).FWidth;
    FAlignment := TGLColumn(ASource).FAlignment;
    Changed(False);
  end
  else inherited Assign(ASource);
end;

procedure TGLColumn.SetCaption(const AValue: string);
begin
  FCaption := AValue;
  Changed(False);
end;

procedure TGLColumn.SetWidth(AValue: Integer);
begin
  FWidth := AValue;
  Changed(False);
end;

procedure TGLColumn.SetAlignment(AValue: TAlignment);
begin
  FAlignment := AValue;
  Changed(False);
end;

{ TGLListItem }

constructor TGLListItem.Create(AOwner: TGLListView);
begin
  inherited Create;
  FOwner := AOwner;
  FSubItems := TStringList.Create;
  FSubItems.OnChange := SubChanged;
end;

destructor TGLListItem.Destroy;
begin
  FSubItems.OnChange := nil;
  FSubItems.Free;
  inherited Destroy;
end;

procedure TGLListItem.SubChanged(Sender: TObject);
begin
  FOwner.ItemsChanged;
end;

procedure TGLListItem.SetCaption(const AValue: string);
begin
  FCaption := AValue;
  FOwner.ItemsChanged;
end;

function TGLListItem.GetIndex: Integer;
begin
  Result := FOwner.Items.FList.IndexOf(Self);
end;

{ TGLListItems }

constructor TGLListItems.Create(AOwner: TGLListView);
begin
  inherited Create;
  FOwner := AOwner;
  FList := TList.Create;
end;

destructor TGLListItems.Destroy;
var
  i: Integer;
begin
  for i := 0 to FList.Count - 1 do TGLListItem(FList[i]).Free;
  FList.Free;
  inherited Destroy;
end;

function TGLListItems.GetCount: Integer;
begin
  Result := FList.Count;
end;

function TGLListItems.GetItem(AIndex: Integer): TGLListItem;
begin
  Result := TGLListItem(FList[AIndex]);
end;

function TGLListItems.Add: TGLListItem;
begin
  Result := TGLListItem.Create(FOwner);
  FList.Add(Result);
  if FUpdating = 0 then FOwner.ItemsChanged;
end;

procedure TGLListItems.Clear;
var
  i: Integer;
begin
  for i := 0 to FList.Count - 1 do TGLListItem(FList[i]).Free;
  FList.Clear;
  if FUpdating = 0 then FOwner.ItemsChanged;
end;

procedure TGLListItems.BeginUpdate;
begin
  Inc(FUpdating);
end;

procedure TGLListItems.EndUpdate;
begin
  if FUpdating > 0 then Dec(FUpdating);
  if FUpdating = 0 then FOwner.ItemsChanged;
end;

{ TGLListView }

{ the visible body ends 3 px above the control's bottom: that strip holds the drop shadow }
function TGLListView.BodyH: Integer;
begin
  Result := Height - 3;
end;

constructor TGLListView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  FColumns := TOwnedCollection.Create(Self, TGLColumn);
  FItems := TGLListItems.Create(Self);
  FIndex := -1;
  FAnchor := -1;
  FHoverIdx := -1;
  FViewStyle := vsIcon;
  Width := 250;
  Height := 150;
  FAnim := TTimer.Create(Self);
  FAnim.Enabled := False;
  FAnim.Interval := 15;
  FAnim.OnTimer := AnimTick;
end;

procedure TGLListView.Kick;
begin
  if (FAnim <> nil) and not (csDesigning in ComponentState) then FAnim.Enabled := True;
end;

{ the selection pill glides to the chosen row and the hover glow follows the mouse - the same
  easing as the menus; the timer only runs while something is moving (or the list has focus and
  its pill is breathing) }
procedure TGLListView.AnimTick(Sender: TObject);
var
  moving: Boolean;
begin
  moving := False;
  if FIndex >= 0 then
  begin
    if FPillAlpha < 0.05 then FPillRow := FIndex;
    FPillRow := FPillRow + (FIndex - FPillRow) * 0.45;
    if Abs(FIndex - FPillRow) < 0.01 then FPillRow := FIndex else moving := True;
    if FPillAlpha < 1 then begin FPillAlpha := System.Math.Min(1, FPillAlpha + 0.25); moving := True; end;
  end
  else if FPillAlpha > 0 then
  begin
    FPillAlpha := System.Math.Max(0, FPillAlpha - 0.2);
    moving := True;
  end;
  if FHoverIdx >= 0 then
  begin
    if FHovAlpha < 0.05 then FHovRow := FHoverIdx;
    FHovRow := FHovRow + (FHoverIdx - FHovRow) * 0.5;
    if Abs(FHoverIdx - FHovRow) < 0.01 then FHovRow := FHoverIdx else moving := True;
    if FHovAlpha < 1 then begin FHovAlpha := System.Math.Min(1, FHovAlpha + 0.3); moving := True; end;
  end
  else if FHovAlpha > 0 then
  begin
    FHovAlpha := System.Math.Max(0, FHovAlpha - 0.25);
    moving := True;
  end;
  FPhase := FPhase + 0.11;
  if (not moving) and not (Focused and (FIndex >= 0)) then FAnim.Enabled := False;
  Invalidate;
end;

procedure TGLListView.CMMouseLeave(var Msg: TMessage);
begin
  inherited;
  if FHoverIdx <> -1 then
  begin
    FHoverIdx := -1;
    Kick;
  end;
end;

destructor TGLListView.Destroy;
begin
  FItems.Free;
  FColumns.Free;
  inherited Destroy;
end;

procedure TGLListView.WMGetDlgCode(var Msg: TWMGetDlgCode);
begin
  inherited;
  Msg.Result := Msg.Result or DLGC_WANTARROWS;
end;

procedure TGLListView.SetColumns(AValue: TCollection);
begin
  FColumns.Assign(AValue);
  Invalidate;
end;

procedure TGLListView.SetGridLines(AValue: Boolean);
begin
  FGridLines := AValue;
  Invalidate;
end;

function TGLListView.IsSelected(AIndex: Integer): Boolean;
begin
  if FMultiSelect then
    Result := (AIndex >= 0) and (AIndex < Length(FSel)) and FSel[AIndex]
  else
    Result := AIndex = FIndex;
end;

function TGLListView.SelCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to FItems.Count - 1 do
    if IsSelected(i) then Inc(Result);
end;

procedure TGLListView.ItemsChanged;
begin
  if Length(FSel) <> FItems.Count then SetLength(FSel, FItems.Count);
  if FIndex >= FItems.Count then FIndex := FItems.Count - 1;
  FTop := EnsureRange(FTop, 0, MaxTop);
  Invalidate;
end;

function TGLListView.GetSelected: TGLListItem;
begin
  if (FIndex >= 0) and (FIndex < FItems.Count) then Result := FItems[FIndex] else Result := nil;
end;

function TGLListView.RowH: Integer;
begin
  Result := Abs(Font.Height) + 9;
end;

function TGLListView.HeaderH: Integer;
begin
  Result := RowH + 2;
end;

function TGLListView.VisibleRows: Integer;
begin
  Result := System.Math.Max(1, (BodyH - HeaderH) div RowH);
end;

function TGLListView.MaxTop: Integer;
begin
  Result := System.Math.Max(0, FItems.Count - VisibleRows);
end;

function TGLListView.NeedBar: Boolean;
begin
  Result := FItems.Count > VisibleRows;
end;

function TGLListView.ThumbRect: TRect;
var
  trackH, th, ty: Integer;
begin
  trackH := BodyH - HeaderH;
  th := System.Math.Max(20, Round(trackH * VisibleRows / System.Math.Max(1, FItems.Count)));
  if MaxTop > 0 then ty := Round((trackH - th) * FTop / MaxTop) else ty := 0;
  Result := Rect(Width - 10, HeaderH + ty, Width - 2, HeaderH + ty + th);
end;

procedure TGLListView.Resize;
begin
  inherited Resize;
  FTop := EnsureRange(FTop, 0, MaxTop);
end;

procedure TGLListView.SetTop(AValue: Integer);
begin
  AValue := EnsureRange(AValue, 0, MaxTop);
  if AValue = FTop then Exit;
  FTop := AValue;
  Invalidate;
end;

procedure TGLListView.SetIndex(AValue: Integer);
begin
  AValue := EnsureRange(AValue, -1, FItems.Count - 1);
  if AValue = FIndex then Exit;
  FIndex := AValue;
  if FIndex >= 0 then
  begin
    if FIndex < FTop then FTop := FIndex
    else if FIndex >= FTop + VisibleRows then FTop := FIndex - VisibleRows + 1;
  end;
  Kick;
  Invalidate;
end;

function TGLListView.ItemAt(X, Y: Integer): Integer;
begin
  Result := -1;
  if (Y < HeaderH) or (Y >= BodyH) or (NeedBar and (X >= Width - 12)) then Exit;
  Result := FTop + (Y - HeaderH) div RowH;
  if (Result < 0) or (Result >= FItems.Count) then Result := -1;
end;

procedure TGLListView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  r, i: Integer;
  tr: TRect;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button <> mbLeft) or not Enabled or (Y < HeaderH) then Exit;
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
  r := FTop + (Y - HeaderH) div RowH;
  if (r >= 0) and (r < FItems.Count) then
  begin
    if FMultiSelect then
    begin
      if Length(FSel) <> FItems.Count then SetLength(FSel, FItems.Count);
      if ssShift in Shift then
      begin
        if FAnchor < 0 then FAnchor := r;
        for i := 0 to High(FSel) do FSel[i] := (i >= System.Math.Min(FAnchor, r)) and (i <= System.Math.Max(FAnchor, r));
      end
      else if ssCtrl in Shift then
      begin
        FSel[r] := not FSel[r];
        FAnchor := r;
      end
      else
      begin
        for i := 0 to High(FSel) do FSel[i] := i = r;
        FAnchor := r;
      end;
    end;
    SetIndex(r);
    Click;
  end;
end;

procedure TGLListView.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  room: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if not FDragging then
  begin
    room := -1;
    if (Y >= HeaderH) and not (NeedBar and (X >= Width - 12)) then
    begin
      room := FTop + (Y - HeaderH) div RowH;
      if room >= FItems.Count then room := -1;
    end;
    if room <> FHoverIdx then
    begin
      FHoverIdx := room;
      Kick;
    end;
    Exit;
  end;
  room := BodyH - HeaderH - (ThumbRect.Bottom - ThumbRect.Top);
  if room > 0 then SetTop(Round(MaxTop * EnsureRange((Y - HeaderH - FGrab) / room, 0, 1)));
end;

procedure TGLListView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FDragging := False;
end;

function TGLListView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := True;
  SetTop(FTop - Sign(WheelDelta) * 3);
end;

procedure TGLListView.KeyDown(var Key: Word; Shift: TShiftState);
var
  n: Integer;
begin
  inherited KeyDown(Key, Shift);
  case Key of
    VK_UP: n := FIndex - 1;
    VK_DOWN: n := FIndex + 1;
    VK_PRIOR: n := FIndex - VisibleRows;
    VK_NEXT: n := FIndex + VisibleRows;
    VK_HOME: n := 0;
    VK_END: n := FItems.Count - 1;
  else
    Exit;
  end;
  Key := 0;
  n := EnsureRange(n, 0, FItems.Count - 1);
  if (n <> FIndex) and (FItems.Count > 0) then
  begin
    SetIndex(n);
    Click;
  end;
end;

procedure TGLListView.PaintGL;
var
  cv: TGLCanvas;
  face, field, gridC, accent, deep, ink: TColor;
  i, c, y, x, rh, th, barW, cw, k, sx: Integer;
  txt: string;
  item: TGLListItem;
  col: TGLColumn;
  tr, pill: TRect;
  pulse: Double;

  procedure Cell(ALeft, AWidth: Integer; AAlign: TAlignment; const S: string; ATop: Integer);
  var
    tx: Integer;
  begin
    cv.PushClip(Rect(ALeft + 2, ATop, ALeft + AWidth - 2, ATop + rh));
    case AAlign of
      taRightJustify: tx := ALeft + AWidth - 6 - cv.TextWidth(S);
      taCenter: tx := ALeft + (AWidth - cv.TextWidth(S)) div 2;
    else
      tx := ALeft + 6;
    end;
    cv.TextOut(tx, ATop + (rh - th) div 2, S);
    cv.PopClip;
  end;

  function RowTop(ARow: Double): Integer;
  begin
    Result := HeaderH + Round((ARow - FTop) * rh);
  end;

begin
  cv := GL;
  face := FaceColor;
  field := FieldColor;
  ink := InkColor;
  accent := SelectionColor;
  deep := Blend(accent, clBlack, 0.62);
  gridC := Blend(field, ink, 0.12);
  rh := RowH;
  th := cv.TextHeight('Ag');
  if NeedBar then barW := 12 else barW := 0;
  pulse := 0.5 + 0.5 * FastSin(FPhase);
  cv.Alpha := 1;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := BackdropColor;
  cv.FillRect(Rect(0, 0, Width, Height));
  DrawDropShadow(cv, Rect(0, 0, Width, BodyH), 6, 3, 1.4);
  cv.GradientRect(Rect(0, 0, Width, BodyH), Blend(field, clBlack, 0.06), Blend(field, clBlack, 0.22));

  { rows: faint zebra stripes, the hover glow, then the selection }
  cv.PushClip(Rect(0, HeaderH, Width - barW, BodyH));
  y := HeaderH;
  for i := FTop to FItems.Count - 1 do
  begin
    if y >= BodyH then Break;
    if Odd(i) then
    begin
      cv.Brush.Color := ink;
      cv.Alpha := 0.035;
      cv.FillRect(Rect(0, y, Width - barW, y + rh));
    end;
    { each row is engraved into the field: a dark groove with a light edge under it }
    cv.Brush.Color := clBlack;
    cv.Alpha := 0.28;
    cv.FillRect(Rect(0, y + rh - 2, Width - barW, y + rh - 1));
    cv.Brush.Color := clWhite;
    cv.Alpha := 0.05;
    cv.FillRect(Rect(0, y + rh - 1, Width - barW, y + rh));
    cv.Alpha := 1;
    Inc(y, rh);
  end;
  if FHovAlpha > 0.02 then
  begin
    cv.Brush.Color := HoverTint;
    cv.Alpha := 0.10 * FHovAlpha;
    cv.RoundRect(3, RowTop(FHovRow) + 1, Width - barW - 3, RowTop(FHovRow) + rh - 1, 7, 7);
    cv.Alpha := 0.14 * FHovAlpha;
    cv.FillRect(Rect(8, RowTop(FHovRow) + 1, Width - barW - 8, RowTop(FHovRow) + 2));
    cv.Alpha := 1;
  end;
  if FMultiSelect then
    for i := FTop to System.Math.Min(FItems.Count - 1, FTop + VisibleRows + 1) do
      if IsSelected(i) and (i <> FIndex) then
      begin
        cv.Alpha := 0.55;
        cv.GradientRect(Rect(2, RowTop(i) + 1, Width - barW - 2, RowTop(i) + rh - 1),
          Blend(accent, clBlack, 0.40), deep);
        cv.Brush.Color := clWhite;
        cv.Alpha := 0.35;
        cv.FillRect(Rect(2, RowTop(i) + 1, Width - barW - 2, RowTop(i) + 2));
        cv.Brush.Color := clBlack;
        cv.Alpha := 0.40;
        cv.FillRect(Rect(2, RowTop(i) + rh - 2, Width - barW - 2, RowTop(i) + rh - 1));
        cv.Alpha := 1;
      end;
  if FPillAlpha > 0.02 then
  begin
    pill := Rect(3, RowTop(FPillRow) + 1, Width - barW - 3, RowTop(FPillRow) + rh - 1);
    { it floats above the rows: a soft shadow beneath and to one side }
    cv.Brush.Color := clBlack;
    cv.Alpha := 0.22 * FPillAlpha;
    cv.RoundRect(pill.Left - 1, pill.Top + 2, pill.Right + 3, pill.Bottom + 5, 12, 12);
    cv.Alpha := 0.34 * FPillAlpha;
    cv.RoundRect(pill.Left + 1, pill.Top + 2, pill.Right + 1, pill.Bottom + 3, 9, 9);
    cv.Brush.Color := accent;
    cv.Alpha := (0.10 + 0.16 * pulse) * FPillAlpha;
    cv.RoundRect(pill.Left - 2, pill.Top - 2, pill.Right + 2, pill.Bottom + 2, 11, 11);
    cv.Alpha := FPillAlpha;
    cv.Brush.Color := deep;
    cv.RoundRect(pill.Left, pill.Top, pill.Right, pill.Bottom, 8, 8);
    cv.Brush.Color := Blend(accent, clBlack, 0.46 - 0.10 * pulse);
    cv.RoundRect(pill.Left, pill.Top, pill.Right, pill.Bottom - 2, 8, 8);
    cv.Brush.Color := clWhite;
    cv.Alpha := 0.14 * FPillAlpha;
    cv.RoundRect(pill.Left + 2, pill.Top + 1, pill.Right - 2, pill.Top + (pill.Bottom - pill.Top) div 2, 6, 6);
    { the slanted band of light that sweeps across the pill }
    cv.PushClip(Rect(pill.Left + 1, pill.Top + 1, pill.Right - 1, pill.Bottom - 1));
    sx := pill.Left - 40 + Round(Frac(FPhase / 8.0) * (pill.Right - pill.Left + 80));
    for k := 0 to 3 do
    begin
      cv.Alpha := (0.05 + 0.05 * k) * FPillAlpha;
      cv.Polygon([Point(sx + k * 5 + 8, pill.Top), Point(sx + 30 - k * 5 + 8, pill.Top),
        Point(sx + 30 - k * 5 - 4, pill.Bottom), Point(sx + k * 5 - 4, pill.Bottom)]);
    end;
    cv.PopClip;
    { bevel: a bright lip along the top and left, a dark one along the bottom and right }
    cv.Brush.Color := clWhite;
    cv.Alpha := 0.55 * FPillAlpha;
    cv.FillRect(Rect(pill.Left + 6, pill.Top + 1, pill.Right - 6, pill.Top + 2));
    cv.FillRect(Rect(pill.Left + 1, pill.Top + 6, pill.Left + 2, pill.Bottom - 6));
    cv.Brush.Color := clBlack;
    cv.Alpha := 0.5 * FPillAlpha;
    cv.FillRect(Rect(pill.Left + 6, pill.Bottom - 2, pill.Right - 6, pill.Bottom - 1));
    cv.FillRect(Rect(pill.Right - 2, pill.Top + 6, pill.Right - 1, pill.Bottom - 6));
    cv.Alpha := 1;
  end;

  { row text, over the pill }
  y := HeaderH;
  for i := FTop to FItems.Count - 1 do
  begin
    if y >= BodyH then Break;
    item := FItems[i];
    if IsSelected(i) then cv.Font.Color := SelectionTextColor
    else cv.Font.Color := Sys(clWindowText);
    x := 0;
    for c := 0 to FColumns.Count - 1 do
    begin
      col := TGLColumn(FColumns.Items[c]);
      if c = 0 then txt := item.Caption
      else if c - 1 < item.SubItems.Count then txt := item.SubItems[c - 1]
      else txt := '';
      Cell(x, col.Width, col.Alignment, txt, y);
      Inc(x, col.Width);
    end;
    if FGridLines then
    begin
      cv.Brush.Color := gridC;
      cv.FillRect(Rect(0, y + rh - 1, Width - barW, y + rh));
    end;
    Inc(y, rh);
  end;
  cv.PopClip;
  if FGridLines then
  begin
    x := 0;
    cv.Brush.Color := gridC;
    for c := 0 to FColumns.Count - 1 do
    begin
      Inc(x, TGLColumn(FColumns.Items[c]).Width);
      cv.FillRect(Rect(x - 1, HeaderH, x, BodyH));
    end;
  end;

  { the rows sit below the header in its shadow }
  cv.Alpha := 1;
  cv.GradientRect(Rect(0, HeaderH, Width - barW, HeaderH + 7), Blend(field, clBlack, 0.75), field);
  { header: a raised plate with a lit top edge, a dark foot and grooved column dividers }
  cv.GradientRect(Rect(0, 0, Width, HeaderH), Blend(face, clWhite, 0.14), Blend(face, clBlack, 0.18));
  cv.Brush.Color := clWhite;
  cv.Alpha := 0.35;
  cv.FillRect(Rect(0, 0, Width, 1));
  cv.Brush.Color := clBlack;
  cv.Alpha := 0.55;
  cv.FillRect(Rect(0, HeaderH - 1, Width, HeaderH));
  cv.Alpha := 1;
  x := 0;
  cv.Font.Color := ink;
  for c := 0 to FColumns.Count - 1 do
  begin
    col := TGLColumn(FColumns.Items[c]);
    cw := col.Width;
    cv.Brush.Color := clBlack;
    cv.Alpha := 0.45;
    cv.FillRect(Rect(x + cw - 2, 3, x + cw - 1, HeaderH - 3));
    cv.Brush.Color := clWhite;
    cv.Alpha := 0.25;
    cv.FillRect(Rect(x + cw - 1, 3, x + cw, HeaderH - 3));
    cv.Alpha := 1;
    cv.PushClip(Rect(x + 2, 0, x + cw - 2, HeaderH));
    cv.TextOut(x + 6, (HeaderH - th) div 2, col.Caption);
    cv.PopClip;
    Inc(x, cw);
  end;

  DrawInsetShadow(cv, Rect(0, HeaderH, Width - barW, BodyH), 4);
  if NeedBar then
  begin
    tr := ThumbRect;
    cv.GradientRect(Rect(Width - 12, HeaderH, Width, BodyH), Blend(field, clBlack, 0.3), Blend(field, ink, 0.06), True);
    GLDrawScrollThumb(cv, Self, 0, tr, True, FDragging, Hover, field, ink, accent);
  end;

  { an inset frame: shadow along the top and left, light along the bottom and right }
  cv.Brush.Color := clBlack;
  cv.Alpha := 0.55;
  cv.FillRect(Rect(0, 0, Width, 1));
  cv.FillRect(Rect(0, 0, 1, BodyH));
  cv.Brush.Color := clWhite;
  cv.Alpha := 0.22;
  cv.FillRect(Rect(0, BodyH - 1, Width, BodyH));
  cv.FillRect(Rect(Width - 1, 0, Width, BodyH));
  cv.Alpha := 1;
  if Focused then
  begin
    cv.Brush.Color := accent;
    cv.Alpha := 0.8;
    cv.FillRect(Rect(1, 1, Width - 1, 2));
    cv.FillRect(Rect(1, BodyH - 2, Width - 1, BodyH - 1));
    cv.FillRect(Rect(1, 1, 2, BodyH - 1));
    cv.FillRect(Rect(Width - 2, 1, Width - 1, BodyH - 1));
    cv.Alpha := 1;
    if not FAnim.Enabled then Kick;
  end;
  cv.Pen.Style := psClear;
end;

{ TGLPage }

constructor TGLPage.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csAcceptsControls];
  FImageIndex := -1;
  FTabVisible := True;
  TabStop := False;
  Width := 200;
  Height := 150;
end;

destructor TGLPage.Destroy;
begin
  inherited Destroy;
end;

function TGLPage.GetPageControl: TGLPageControl;
begin
  if Parent is TGLPageControl then Result := TGLPageControl(Parent) else Result := nil;
end;

function TGLPage.GetPageIndex: Integer;
begin
  if GetPageControl <> nil then Result := GetPageControl.FPages.IndexOf(Self) else Result := -1;
end;

procedure TGLPage.SetParent(AParent: TWinControl);
var
  old: TGLPageControl;
begin
  old := GetPageControl;
  if (old <> nil) and (old <> AParent) then old.RemovePage(Self);
  inherited SetParent(AParent);
  if (AParent is TGLPageControl) and (AParent <> old) then TGLPageControl(AParent).AddPage(Self);
end;

procedure TGLPage.CaptionChanged;
begin
  if GetPageControl <> nil then GetPageControl.PageChanged;
end;

procedure TGLPage.SetTabVisible(AValue: Boolean);
begin
  if FTabVisible = AValue then Exit;
  FTabVisible := AValue;
  if GetPageControl <> nil then GetPageControl.PageChanged;
end;

const
  PAGE_DEFAULT_W = 200;
  PAGE_DEFAULT_H = 150;

{ A page is created PAGE_DEFAULT_W x PAGE_DEFAULT_H and only becomes alClient
  later, so its children's anchor baseline is that default size and the first
  real resize flings right/bottom-anchored children out of view. The designed
  bounds are remembered here and re-applied (which also re-baselines the
  anchors) as soon as the page has its real size. }
procedure TGLPage.Loaded;
var
  i: Integer;
begin
  inherited Loaded;
  SetLength(FDesignBounds, ControlCount);
  for i := 0 to ControlCount - 1 do
    FDesignBounds[i] := Controls[i].BoundsRect;
  FRebased := False;
end;

procedure TGLPage.AlignControls(AControl: TControl; var ARect: TRect);
var
  i: Integer;
  c: TControl;
begin
  inherited AlignControls(AControl, ARect);
  if FRebased or FRebasing or (csLoading in ComponentState) or (csDesigning in ComponentState) then Exit;
  if (Width = PAGE_DEFAULT_W) and (Height = PAGE_DEFAULT_H) then Exit;   // not sized yet
  FRebased := True;
  if Length(FDesignBounds) <> ControlCount then Exit;
  FRebasing := True;
  try
    for i := 0 to ControlCount - 1 do
    begin
      c := Controls[i];
      if c.Align <> alNone then Continue;
      c.BoundsRect := FDesignBounds[i];
    end;
  finally
    FRebasing := False;
  end;
end;

procedure TGLPage.PaintGL;
begin
  GL.Brush.Style := bsSolid;
  GL.Pen.Style := psClear;
  GL.Brush.Color := FaceColor;
  GL.FillRect(Rect(0, 0, Width, Height));
end;

const
  TAB_ARROW_W = 16;   { the scroll arrows at each end of an overflowing tab row }

{ the two scroll arrows of a tab row that is wider than its control }
procedure PaintTabArrows(cv: TGLCanvas; AWidth, AHeight, AScroll, AMax: Integer; AInk, AFace: TColor);
var
  cy: Integer;
begin
  cy := AHeight div 2;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := AFace;
  cv.FillRect(Rect(0, 0, TAB_ARROW_W, AHeight));
  cv.FillRect(Rect(AWidth - TAB_ARROW_W, 0, AWidth, AHeight));
  if AScroll > 0 then cv.Brush.Color := AInk else cv.Brush.Color := Blend(AFace, AInk, 0.3);
  cv.Polygon([Point(11, cy - 5), Point(11, cy + 5), Point(5, cy)]);
  if AScroll < AMax then cv.Brush.Color := AInk else cv.Brush.Color := Blend(AFace, AInk, 0.3);
  cv.Polygon([Point(AWidth - 11, cy - 5), Point(AWidth - 11, cy + 5), Point(AWidth - 5, cy)]);
end;

{ TGLTabHeader }

constructor TGLTabHeader.CreateFor(AOwner: TGLPageControl);
begin
  inherited Create(AOwner);
  FOwnerPC := AOwner;
  FHoverTab := -1;
  TabStop := False;
  Parent := AOwner;
  Align := alTop;
  Height := 28;
  FAnim := TTimer.Create(Self);
  FAnim.Enabled := False;
  FAnim.Interval := 15;
  FAnim.OnTimer := AnimTick;
end;

{ the active-tab pill glides to a newly chosen tab (the menus' easing) and a band of light keeps
  sweeping across it, like the menus' highlight; the timer stops while the tab row is not on screen
  and PaintGL starts it again }
procedure TGLTabHeader.AnimTick(Sender: TObject);
var
  moving: Boolean;
begin
  moving := (Abs(FGoalL - FPillL) >= 0.5) or (Abs(FGoalR - FPillR) >= 0.5);
  FPillL := FPillL + (FGoalL - FPillL) * 0.32;
  FPillR := FPillR + (FGoalR - FPillR) * 0.32;
  if Abs(FGoalL - FPillL) < 0.5 then FPillL := FGoalL;
  if Abs(FGoalR - FPillR) < 0.5 then FPillR := FGoalR;
  FPhase := FPhase + 0.11;
  if (not moving) and not Showing then FAnim.Enabled := False;
  Invalidate;
end;

procedure TGLTabHeader.CMMouseLeave(var Msg: TMessage);
begin
  inherited;
  if FHoverTab <> -1 then
  begin
    FHoverTab := -1;
    Invalidate;
  end;
end;

procedure TGLTabHeader.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  i, t: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  t := -1;
  if not (FOwnerPC.FTabOver and ((X < TAB_ARROW_W) or (X >= Width - TAB_ARROW_W))) then
    for i := 0 to High(FOwnerPC.FTabRects) do
      if PtInRect(FOwnerPC.FTabRects[i], Point(X, Y)) then t := i;
  if t <> FHoverTab then
  begin
    FHoverTab := t;
    Invalidate;
  end;
end;

procedure TGLTabHeader.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  i: Integer;
begin
  inherited MouseUp(Button, Shift, X, Y);
  if (Button <> mbLeft) or not Enabled then Exit;
  if FOwnerPC.FTabOver then
  begin
    if X < TAB_ARROW_W then
    begin
      FOwnerPC.ScrollTabs(-80);
      Exit;
    end;
    if X >= Width - TAB_ARROW_W then
    begin
      FOwnerPC.ScrollTabs(80);
      Exit;
    end;
  end;
  for i := 0 to High(FOwnerPC.FTabRects) do
    if PtInRect(FOwnerPC.FTabRects[i], Point(X, Y)) then
    begin
      FOwnerPC.UserSelect(FOwnerPC.FTabPages[i]);
      Exit;
    end;
end;

function TGLTabHeader.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := FOwnerPC.FTabOver;
  if Result then FOwnerPC.ScrollTabs(-Sign(WheelDelta) * 80);
end;

procedure TGLTabHeader.PaintGL;
var
  cv: TGLCanvas;
  face, accent, deep: TColor;
  i, k, sx, act: Integer;
  r, pr: TRect;
  cap: string;
  pulse: Double;

  { a tab body with rounded top corners and a square foot: the rounded rectangle runs past the
    bottom edge and is clipped }
  procedure TabBody(const R: TRect; AColor: TColor; AAlpha: Double);
  begin
    cv.PushClip(Rect(R.Left, R.Top, R.Right, R.Bottom - 1));
    cv.Brush.Color := AColor;
    cv.Alpha := AAlpha;
    cv.RoundRect(R.Left, R.Top, R.Right, R.Bottom + 12, 11, 11);
    cv.PopClip;
    cv.Alpha := 1;
  end;

begin
  FOwnerPC.EnsureLayout;
  cv := GL;
  face := FaceColor;
  accent := TColor($3830D8);   { the page tabs are lit red, whatever the theme's accent is }
  deep := Blend(accent, clBlack, 0.38);
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := face;
  cv.FillRect(Rect(0, 0, Width, Height));
  if FOwnerPC.FTabOver then cv.PushClip(Rect(TAB_ARROW_W, 0, Width - TAB_ARROW_W, Height));

  { idle and hovered tabs }
  act := -1;
  for i := 0 to High(FOwnerPC.FTabRects) do
  begin
    r := FOwnerPC.FTabRects[i];
    if FOwnerPC.FTabPages[i] = FOwnerPC.FActive then
    begin
      act := i;
      Continue;
    end;
    if i = FHoverTab then TabBody(Rect(r.Left + 1, r.Top + 2, r.Right - 1, r.Bottom), Blend(face, InkColor, 0.16), 1)
    else TabBody(Rect(r.Left + 1, r.Top + 2, r.Right - 1, r.Bottom), Blend(face, InkColor, 0.05), 1);
    DrawTabSunken(cv, Rect(r.Left + 1, r.Top + 2, r.Right - 1, r.Bottom), IfThen(i = FHoverTab, 0.7, 1.0),
      Blend(face, InkColor, IfThen(i = FHoverTab, 0.16, 0.05)));
  end;

  { the active tab: a pill that glides from tab to tab, lit like a selected menu item }
  if act >= 0 then
  begin
    r := FOwnerPC.FTabRects[act];
    if (FGoalL <> r.Left + 1) or (FGoalR <> r.Right - 1) or not FPillInit then
    begin
      FGoalL := r.Left + 1;
      FGoalR := r.Right - 1;
      if not FPillInit or (csDesigning in ComponentState) then
      begin
        FPillInit := True;
        FPillL := FGoalL;
        FPillR := FGoalR;
      end
    end;
    if not FAnim.Enabled and not (csDesigning in ComponentState) then FAnim.Enabled := True;
    pr := Rect(Round(FPillL), r.Top + 2, Round(FPillR), r.Bottom);
    pulse := 0.5 + 0.5 * FastSin(FPhase);
    DrawTabShadow(cv, pr, 1.6);
    { a soft halo, the deep body, the lighter face and a glossy band across the top }
    TabBody(Rect(pr.Left - 2, pr.Top - 2, pr.Right + 2, pr.Bottom), accent, 0.12 + 0.12 * pulse);
    TabBody(pr, deep, 1);
    TabBody(Rect(pr.Left, pr.Top, pr.Right, pr.Bottom - 2), Blend(accent, clWhite, 0.06 + 0.12 * pulse), 1);
    cv.PushClip(Rect(pr.Left + 2, pr.Top + 1, pr.Right - 2, pr.Top + (pr.Bottom - pr.Top) div 2));
    cv.Brush.Color := clWhite;
    cv.Alpha := 0.14;
    cv.RoundRect(pr.Left + 2, pr.Top + 1, pr.Right - 2, pr.Top + (pr.Bottom - pr.Top) + 10, 9, 9);
    cv.PopClip;
    { the slanted band of light that sweeps across the pill }
    cv.PushClip(Rect(pr.Left + 2, pr.Top + 1, pr.Right - 2, pr.Bottom - 1));
    sx := pr.Left - 40 + Round(Frac(FPhase / 8.0) * (pr.Right - pr.Left + 80));
    cv.Brush.Color := clWhite;
    for k := 0 to 3 do
    begin
      cv.Alpha := 0.05 + 0.05 * k;
      cv.Polygon([Point(sx + k * 5 + 8, pr.Top), Point(sx + 30 - k * 5 + 8, pr.Top),
        Point(sx + 30 - k * 5 - 4, pr.Bottom), Point(sx + k * 5 - 4, pr.Bottom)]);
    end;
    cv.PopClip;
    cv.Alpha := 1;
    DrawTabRaised(cv, pr, 1.2, False);
    if FOwnerPC.Focused then
    begin
      cv.Pen.Style := psSolid;
      cv.Pen.Color := Blend(accent, clWhite, 0.5);
      cv.Brush.Style := bsClear;
      cv.RoundRect(pr.Left, pr.Top, pr.Right, pr.Bottom + 8, 11, 11);
      cv.Brush.Style := bsSolid;
      cv.Pen.Style := psClear;
    end;
  end;

  { captions over everything }
  for i := 0 to High(FOwnerPC.FTabRects) do
  begin
    r := FOwnerPC.FTabRects[i];
    cap := FOwnerPC.FTabPages[i].ShownCaption;
    cv.PushClip(Rect(r.Left + 2, r.Top, r.Right - 2, r.Bottom));
    cv.Font.Color := InkColor;
    cv.TextOut(r.Left + (r.Right - r.Left - cv.TextWidth(cap)) div 2,
      r.Top + (r.Bottom - r.Top - cv.TextHeight(cap)) div 2, cap);
    cv.PopClip;
  end;
  if FOwnerPC.FTabOver then
  begin
    cv.PopClip;
    PaintTabArrows(cv, Width, Height, FOwnerPC.FTabScroll, FOwnerPC.FTabMax, InkColor, face);
  end;
  cv.Brush.Color := Blend(face, InkColor, 0.2);
  cv.FillRect(Rect(0, Height - 1, Width, Height));
end;

{ TGLPageControl }

procedure TGLPageControl.ScrollTabs(ADelta: Integer);
var
  was: Integer;
begin
  was := FTabScroll;
  FTabScroll := EnsureRange(FTabScroll + ADelta, 0, System.Math.Max(0, FTabMax));
  if FTabScroll = was then Exit;
  FLayoutValid := False;
  if FHeader <> nil then FHeader.Invalidate;
end;

{ brings the active tab inside the visible part of an overflowing tab row }
procedure TGLPageControl.RevealActiveTab;
var
  i: Integer;
begin
  if (FHeader = nil) or (FActive = nil) then Exit;
  EnsureLayout;
  if not FTabOver then Exit;
  for i := 0 to High(FTabPages) do
    if FTabPages[i] = FActive then
    begin
      if FTabRects[i].Left < TAB_ARROW_W then ScrollTabs(FTabRects[i].Left - TAB_ARROW_W)
      else if FTabRects[i].Right > ClientWidth - TAB_ARROW_W then
        ScrollTabs(FTabRects[i].Right - (ClientWidth - TAB_ARROW_W));
      Exit;
    end;
end;

constructor TGLPageControl.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csAcceptsControls, csOpaque];
  TabStop := True;
  FPages := TList.Create;
  FMeasure := TBitmap.Create;
  FMeasure.SetSize(8, 8);
  Width := 289;
  Height := 193;
  FTabsVisible := True;
  FHeader := TGLTabHeader.CreateFor(Self);
end;

procedure TGLPageControl.SetTabsVisible(AValue: Boolean);
begin
  if FTabsVisible = AValue then Exit;
  FTabsVisible := AValue;
  if FHeader <> nil then FHeader.Visible := AValue;
  Realign;
end;

destructor TGLPageControl.Destroy;
begin
  FMeasure.Free;
  FPages.Free;
  inherited Destroy;
end;

procedure TGLPageControl.WMEraseBkgnd(var Msg: TWMEraseBkgnd);
begin
  Msg.Result := 1;
end;

procedure TGLPageControl.WMGetDlgCode(var Msg: TWMGetDlgCode);
begin
  inherited;
  Msg.Result := Msg.Result or DLGC_WANTARROWS;
end;

procedure TGLPageControl.WMSetFocus(var Msg: TWMSetFocus);
begin
  inherited;
  if FHeader <> nil then FHeader.Invalidate;
end;

procedure TGLPageControl.WMKillFocus(var Msg: TWMKillFocus);
begin
  inherited;
  if FHeader <> nil then FHeader.Invalidate;
end;

procedure TGLPageControl.CMFontChanged(var Msg: TMessage);
begin
  inherited;
  Relayout;
end;

procedure TGLPageControl.Paint;
begin
  Canvas.Brush.Color := Sys(clBtnFace);
  Canvas.FillRect(ClientRect);
end;

procedure TGLPageControl.Resize;
begin
  inherited Resize;
  Relayout;
end;

function TGLPageControl.GetPageCount: Integer;
begin
  Result := FPages.Count;
end;

function TGLPageControl.GetPage(AIndex: Integer): TGLPage;
begin
  Result := TGLPage(FPages[AIndex]);
end;

function TGLPageControl.GetActivePageIndex: Integer;
begin
  Result := FPages.IndexOf(FActive);
end;

procedure TGLPageControl.SetActivePageIndex(AValue: Integer);
begin
  if (AValue >= 0) and (AValue < FPages.Count) then SetActivePage(GetPage(AValue));
end;

procedure TGLPageControl.SetMultiLine(AValue: Boolean);
begin
  if FMultiLine = AValue then Exit;
  FMultiLine := AValue;
  Relayout;
end;

procedure TGLPageControl.AddPage(APage: TGLPage);
begin
  if FPages.IndexOf(APage) >= 0 then Exit;
  FPages.Add(APage);
  APage.Align := alClient;
  if FActive = nil then FActive := APage
  else APage.Visible := False;
  Relayout;
end;

procedure TGLPageControl.RemovePage(APage: TGLPage);
var
  i: Integer;
begin
  FPages.Remove(APage);
  if FActive = APage then
  begin
    FActive := nil;
    for i := 0 to FPages.Count - 1 do
      if GetPage(i).TabVisible then
      begin
        SetActivePage(GetPage(i));
        Break;
      end;
  end;
  Relayout;
end;

procedure TGLPageControl.SetActivePage(AValue: TGLPage);
var
  i: Integer;
begin
  if (AValue = nil) or (FPages.IndexOf(AValue) < 0) then Exit;
  FActive := AValue;
  for i := 0 to FPages.Count - 1 do
    GetPage(i).Visible := GetPage(i) = AValue;
  if FHeader <> nil then FHeader.Invalidate;
  RevealActiveTab;
end;

procedure TGLPageControl.PageChanged;
begin
  if (FActive <> nil) and not FActive.TabVisible then SelectNextPage(True);
  Relayout;
end;

procedure TGLPageControl.SelectNextPage(AGoForward: Boolean);
var
  i, n, step, idx: Integer;
begin
  if FPages.Count = 0 then Exit;
  idx := FPages.IndexOf(FActive);
  if AGoForward then step := 1 else step := -1;
  for n := 1 to FPages.Count do
  begin
    i := (idx + step * n + FPages.Count * 2) mod FPages.Count;
    if GetPage(i).TabVisible then
    begin
      SetActivePage(GetPage(i));
      Exit;
    end;
  end;
end;

procedure TGLPageControl.UserSelect(APage: TGLPage);
begin
  if APage = nil then Exit;
  if CanFocus and not Focused then SetFocus;
  if APage = FActive then Exit;
  SetActivePage(APage);
  if Assigned(FOnChange) then FOnChange(Self);
end;

procedure TGLPageControl.KeyDown(var Key: Word; Shift: TShiftState);
var
  was: TGLPage;
begin
  inherited KeyDown(Key, Shift);
  if (Key <> VK_LEFT) and (Key <> VK_RIGHT) then Exit;
  was := FActive;
  SelectNextPage(Key = VK_RIGHT);
  Key := 0;
  if (FActive <> was) and Assigned(FOnChange) then FOnChange(Self);
end;

{ equal-height tabs sized to their captions; when they do not fit and MultiLine
  is off they share the width }
procedure TGLPageControl.EnsureLayout;
var
  i, x, y, w, rowH, total: Integer;
  pg: TGLPage;
begin
  if FLayoutValid and (FLayoutW = ClientWidth) then Exit;
  FMeasure.Canvas.Font.Assign(Font);
  rowH := FMeasure.Canvas.TextHeight('Ag') + 12;
  SetLength(FTabRects, 0);
  SetLength(FTabPages, 0);
  x := 0;
  y := 0;
  total := 0;
  for i := 0 to FPages.Count - 1 do
  begin
    pg := GetPage(i);
    if not pg.TabVisible then Continue;
    w := System.Math.Max(48, FMeasure.Canvas.TextWidth(pg.ShownCaption) + 24);
    if FMultiLine and (x + w > ClientWidth) and (x > 0) then
    begin
      x := 0;
      Inc(y, rowH + 4);
    end;
    SetLength(FTabRects, Length(FTabRects) + 1);
    SetLength(FTabPages, Length(FTabPages) + 1);
    FTabRects[High(FTabRects)] := Rect(x, y, x + w, y + rowH);
    FTabPages[High(FTabPages)] := pg;
    Inc(x, w);
    Inc(total, w);
  end;
  { tabs that do not fit keep their natural width and scroll between two arrows }
  FTabOver := (not FMultiLine) and (total > ClientWidth) and (total > 0);
  if FTabOver then
  begin
    FTabMax := System.Math.Max(0, total - (ClientWidth - 2 * TAB_ARROW_W));
    FTabScroll := EnsureRange(FTabScroll, 0, FTabMax);
    for i := 0 to High(FTabRects) do OffsetRect(FTabRects[i], TAB_ARROW_W - FTabScroll, 0);
  end
  else
  begin
    FTabScroll := 0;
    FTabMax := 0;
  end;
  FLayoutW := ClientWidth;
  FLayoutValid := True;
end;

function TGLPageControl.LastTabRect: TRect;
begin
  EnsureLayout;
  if Length(FTabRects) > 0 then Result := FTabRects[High(FTabRects)]
  else Result := Rect(0, 0, 0, 28);
end;

procedure TGLPageControl.Relayout;
var
  h: Integer;
begin
  FLayoutValid := False;
  if FHeader = nil then Exit;
  EnsureLayout;
  if Length(FTabRects) > 0 then h := FTabRects[High(FTabRects)].Bottom + 4   // 4 rows hold the shadow
  else h := 28;
  if FHeader.Height <> h then FHeader.Height := h;
  FHeader.Invalidate;
end;

procedure TGLPageControl.Loaded;
begin
  inherited Loaded;
  Relayout;
  if FActive <> nil then SetActivePage(FActive);
end;

{ TGLSplitter }

constructor TGLSplitter.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := False;
  FMinSize := 30;
  FResizeStyle := rsPattern;
  Align := alLeft;
  Width := 5;
  Height := 100;
  Cursor := crHSplit;
end;

function TGLSplitter.IsHorizontalBar: Boolean;
begin
  Result := Align in [alTop, alBottom];
end;

function TGLSplitter.FindNeighbor: TControl;
var
  i: Integer;
  c: TControl;
begin
  Result := nil;
  if Parent = nil then Exit;
  for i := 0 to Parent.ControlCount - 1 do
  begin
    c := Parent.Controls[i];
    if (c = Self) or not c.Visible or (c.Align <> Align) then Continue;
    case Align of
      alTop: if c.Top + c.Height = Top then Exit(c);
      alBottom: if c.Top = Top + Height then Exit(c);
      alLeft: if c.Left + c.Width = Left then Exit(c);
      alRight: if c.Left = Left + Width then Exit(c);
    end;
  end;
end;

procedure TGLSplitter.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;
  FNeighbor := FindNeighbor;
  if FNeighbor = nil then Exit;
  FDragging := True;
  if IsHorizontalBar then
  begin
    FDownAt := ClientToParent(Point(X, Y)).Y;
    FStartSize := FNeighbor.Height;
  end
  else
  begin
    FDownAt := ClientToParent(Point(X, Y)).X;
    FStartSize := FNeighbor.Width;
  end;
end;

procedure TGLSplitter.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  pos, delta, ns, room: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if not FDragging or (FNeighbor = nil) then Exit;
  if IsHorizontalBar then pos := ClientToParent(Point(X, Y)).Y else pos := ClientToParent(Point(X, Y)).X;
  delta := pos - FDownAt;
  { the neighbour grows when the divider moves away from it }
  if Align in [alBottom, alRight] then ns := FStartSize - delta else ns := FStartSize + delta;
  if IsHorizontalBar then room := Parent.ClientHeight - Height - FMinSize
  else room := Parent.ClientWidth - Width - FMinSize;
  ns := EnsureRange(ns, FMinSize, System.Math.Max(FMinSize, room));
  if IsHorizontalBar then FNeighbor.Height := ns else FNeighbor.Width := ns;
end;

procedure TGLSplitter.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if FDragging and Assigned(FOnMoved) then
  begin
    FDragging := False;
    FNeighbor := nil;
    FOnMoved(Self);
    Exit;
  end;
  FDragging := False;
  FNeighbor := nil;
end;

procedure TGLSplitter.PaintGL;
var
  cv: TGLCanvas;
  face: TColor;
  i, cx, cy: Integer;
begin
  cv := GL;
  face := FaceColor;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  if Hover or FDragging then cv.Brush.Color := Blend(face, AccentColor, 0.35)
  else cv.Brush.Color := Blend(face, InkColor, 0.08);
  cv.FillRect(Rect(0, 0, Width, Height));
  cv.Brush.Color := Blend(face, InkColor, 0.45);
  cx := Width shr 1;
  cy := Height shr 1;
  for i := -1 to 1 do
    if IsHorizontalBar then cv.FillRect(Rect(cx + i * 8 - 1, cy - 1, cx + i * 8 + 1, cy + 1))
    else cv.FillRect(Rect(cx - 1, cy + i * 8 - 1, cx + 1, cy + i * 8 + 1));
end;

{ TGLScrollAxis }

constructor TGLScrollAxis.Create(ABox: TGLScrollBox; AVertical: Boolean);
begin
  inherited Create;
  FBox := ABox;
  FVertical := AVertical;
end;

function TGLScrollAxis.GetPosition: Integer;
begin
  if FVertical then Result := FBox.FPosY else Result := FBox.FPosX;
end;

procedure TGLScrollAxis.SetPosition(AValue: Integer);
begin
  if FVertical then FBox.SetScroll(AValue) else FBox.SetScrollX(AValue);
end;

function TGLScrollAxis.GetRange: Integer;
begin
  if FVertical then Result := FBox.ContentHeight else Result := FBox.ContentWidth;
end;

{ TGLScrollBox }

constructor TGLScrollBox.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csAcceptsControls];
  TabStop := False;
  FPad := 8;
  FVert := TGLScrollAxis.Create(Self, True);
  FHorz := TGLScrollAxis.Create(Self, False);
  Width := 185;
  Height := 140;
end;

destructor TGLScrollBox.Destroy;
begin
  FHorz.Free;
  FVert.Free;
  inherited Destroy;
end;

{ bottom edge of the lowest child, measured as if nothing were scrolled }
function TGLScrollBox.ContentHeight: Integer;
var
  i: Integer;
  c: TControl;
begin
  Result := 0;
  for i := 0 to ControlCount - 1 do
  begin
    c := Controls[i];
    if c.Visible then Result := System.Math.Max(Result, c.Top + FPosY + c.Height);
  end;
  Inc(Result, FPad + FBottomPad);
end;

{ right edge of the rightmost child, measured as if nothing were scrolled }
function TGLScrollBox.ContentWidth: Integer;
var
  i: Integer;
  c: TControl;
begin
  Result := 0;
  for i := 0 to ControlCount - 1 do
  begin
    c := Controls[i];
    if c.Visible then Result := System.Math.Max(Result, c.Left + FPosX + c.Width);
  end;
  Inc(Result, FPad);
end;

function TGLScrollBox.MaxPos: Integer;
begin
  Result := System.Math.Max(0, ContentHeight - ClientHeight);
end;

function TGLScrollBox.MaxPosX: Integer;
begin
  Result := System.Math.Max(0, ContentWidth - ClientWidth);
end;

function TGLScrollBox.NeedBar: Boolean;
begin
  Result := ContentHeight > ClientHeight;
end;

function TGLScrollBox.NeedBarX: Boolean;
begin
  Result := ContentWidth > ClientWidth;
end;

procedure TGLScrollBox.SetScrollX(AValue: Integer);
var
  np, delta: Integer;
begin
  np := EnsureRange(AValue, 0, MaxPosX);
  delta := np - FPosX;
  if delta = 0 then Exit;
  FPosX := np;
  ScrollBy(-delta, 0);
  Invalidate;
end;

function TGLScrollBox.ThumbRectX: TRect;
var
  tw, tx, cont: Integer;
begin
  cont := System.Math.Max(1, ContentWidth);
  tw := System.Math.Max(24, Round(Width * ClientWidth / cont));
  if MaxPosX > 0 then tx := Round((Width - tw) * FPosX / MaxPosX) else tx := 0;
  Result := Rect(tx, Height - 10, tx + tw, Height - 2);
end;

procedure TGLScrollBox.SetScroll(AValue: Integer);
var
  np, delta: Integer;
begin
  np := EnsureRange(AValue, 0, MaxPos);
  delta := np - FPosY;
  if delta = 0 then Exit;
  FPosY := np;
  ScrollBy(0, -delta);
  Invalidate;
end;

procedure TGLScrollBox.Resize;
begin
  inherited Resize;
  if FPosY > MaxPos then SetScroll(MaxPos);
  if FPosX > MaxPosX then SetScrollX(MaxPosX);
end;

function TGLScrollBox.ThumbRect: TRect;
var
  th, ty, cont: Integer;
begin
  cont := System.Math.Max(1, ContentHeight);
  th := System.Math.Max(24, Round(Height * ClientHeight / cont));
  if MaxPos > 0 then ty := Round((Height - th) * FPosY / MaxPos) else ty := 0;
  Result := Rect(Width - 10, ty, Width - 2, ty + th);
end;

procedure TGLScrollBox.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  tr: TRect;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button = mbLeft) and NeedBarX and (Y >= Height - 12) then
  begin
    tr := ThumbRectX;
    if (X >= tr.Left) and (X < tr.Right) then
    begin
      FDraggingX := True;
      FGrab := X - tr.Left;
    end
    else if X < tr.Left then SetScrollX(FPosX - ClientWidth)
    else SetScrollX(FPosX + ClientWidth);
    Exit;
  end;
  if (Button <> mbLeft) or not NeedBar or (X < Width - 12) then Exit;
  tr := ThumbRect;
  if (Y >= tr.Top) and (Y < tr.Bottom) then
  begin
    FDragging := True;
    FGrab := Y - tr.Top;
  end
  else if Y < tr.Top then SetScroll(FPosY - ClientHeight)
  else SetScroll(FPosY + ClientHeight);
end;

procedure TGLScrollBox.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  room: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if FDraggingX then
  begin
    room := Width - (ThumbRectX.Right - ThumbRectX.Left);
    if room > 0 then SetScrollX(Round(MaxPosX * EnsureRange((X - FGrab) / room, 0, 1)));
    Exit;
  end;
  if not FDragging then Exit;
  room := Height - (ThumbRect.Bottom - ThumbRect.Top);
  if room > 0 then SetScroll(Round(MaxPos * EnsureRange((Y - FGrab) / room, 0, 1)));
end;

procedure TGLScrollBox.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FDragging := False;
  FDraggingX := False;
end;

function TGLScrollBox.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := True;
  if NeedBarX and ((ssShift in Shift) or not NeedBar) then
    SetScrollX(FPosX - Sign(WheelDelta) * 48)
  else
    SetScroll(FPosY - Sign(WheelDelta) * 48);
end;

procedure TGLScrollBox.PaintGL;
var
  cv: TGLCanvas;
  face: TColor;
  tr: TRect;
begin
  cv := GL;
  face := FaceColor;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := face;
  cv.FillRect(Rect(0, 0, Width, Height));
  if NeedBar then
  begin
    tr := ThumbRect;
    cv.Brush.Color := Blend(face, InkColor, 0.08);
    cv.FillRect(Rect(Width - 12, 0, Width, Height));
    GLDrawScrollThumb(cv, Self, 0, tr, True, FDragging, Hover, face, InkColor, AccentColor);
  end;
  if NeedBarX then
  begin
    tr := ThumbRectX;
    cv.Brush.Color := Blend(face, InkColor, 0.08);
    cv.FillRect(Rect(0, Height - 12, Width, Height));
    GLDrawScrollThumb(cv, Self, 1, tr, False, FDraggingX, Hover, face, InkColor, AccentColor);
  end;
end;

{ TGLStatusPanel }

constructor TGLStatusPanel.Create(ACollection: TCollection);
begin
  inherited Create(ACollection);
  FWidth := 100;
end;

procedure TGLStatusPanel.SetText(const AValue: string);
begin
  FText := AValue;
  Changed(False);
end;

procedure TGLStatusPanel.SetWidth(AValue: Integer);
begin
  FWidth := AValue;
  Changed(False);
end;

{ TGLStatusBar }

constructor TGLStatusBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := False;
  FPanels := TOwnedCollection.Create(Self, TGLStatusPanel);
  Align := alBottom;
  Width := 400;
  Height := 22;
end;

destructor TGLStatusBar.Destroy;
begin
  FPanels.Free;
  inherited Destroy;
end;

procedure TGLStatusBar.SetSimpleText(const AValue: string);
begin
  if FSimpleText = AValue then Exit;
  FSimpleText := AValue;
  Invalidate;
end;

procedure TGLStatusBar.SetSimplePanel(AValue: Boolean);
begin
  FSimplePanel := AValue;
  Invalidate;
end;

procedure TGLStatusBar.SetPanels(AValue: TCollection);
begin
  FPanels.Assign(AValue);
  Invalidate;
end;

procedure TGLStatusBar.PaintGL;
var
  cv: TGLCanvas;
  face: TColor;
  i, x, th: Integer;
  pn: TGLStatusPanel;
begin
  cv := GL;
  face := FaceColor;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := face;
  cv.FillRect(Rect(0, 0, Width, Height));
  cv.Brush.Color := Blend(face, InkColor, 0.2);
  cv.FillRect(Rect(0, 0, Width, 1));
  cv.Font.Color := InkColor;
  th := cv.TextHeight('Ag');
  if FSimplePanel or (FPanels.Count = 0) then
    cv.TextOut(6, (Height - th) div 2, FSimpleText)
  else
  begin
    x := 0;
    for i := 0 to FPanels.Count - 1 do
    begin
      pn := TGLStatusPanel(FPanels.Items[i]);
      cv.PushClip(Rect(x + 2, 0, x + pn.Width - 2, Height));
      cv.TextOut(x + 6, (Height - th) div 2, pn.Text);
      cv.PopClip;
      Inc(x, pn.Width);
      cv.Brush.Color := Blend(face, InkColor, 0.2);
      cv.FillRect(Rect(x - 1, 3, x, Height - 3));
    end;
  end;
end;

{ TGLTreeNode }

constructor TGLTreeNode.Create(AOwner: TGLTree; AParent: TGLTreeNode);
begin
  inherited Create;
  FOwner := AOwner;
  FParent := AParent;
  FKids := TList.Create;
end;

destructor TGLTreeNode.Destroy;
var
  i: Integer;
begin
  for i := 0 to FKids.Count - 1 do TGLTreeNode(FKids[i]).Free;
  FKids.Free;
  inherited Destroy;
end;

function TGLTreeNode.GetCount: Integer;
begin
  Result := FKids.Count;
end;

function TGLTreeNode.GetItem(AIndex: Integer): TGLTreeNode;
begin
  Result := TGLTreeNode(FKids[AIndex]);
end;

function TGLTreeNode.GetLevel: Integer;
var
  n: TGLTreeNode;
begin
  Result := 0;
  n := FParent;
  while n <> nil do
  begin
    Inc(Result);
    n := n.FParent;
  end;
end;

function TGLTreeNode.GetSelected: Boolean;
begin
  Result := FOwner.Selected = Self;
end;

procedure TGLTreeNode.SetSelected(AValue: Boolean);
begin
  if AValue then FOwner.Selected := Self
  else if FOwner.Selected = Self then FOwner.Selected := nil;
end;

procedure TGLTreeNode.SetText(const AValue: string);
begin
  FText := AValue;
  FOwner.NodesChanged;
end;

procedure TGLTreeNode.DeleteChildren;
var
  i: Integer;
begin
  for i := 0 to FKids.Count - 1 do
  begin
    FOwner.NodeRemoved(TGLTreeNode(FKids[i]));
    TGLTreeNode(FKids[i]).Free;
  end;
  FKids.Clear;
  FOwner.NodesChanged;
end;

procedure TGLTreeNode.Delete;
begin
  FOwner.NodeRemoved(Self);
  if FParent <> nil then FParent.FKids.Remove(Self)
  else FOwner.FNodes.FRoots.Remove(Self);
  FOwner.NodesChanged;
  Free;
end;

procedure TGLTreeNode.Expand(ARecurse: Boolean);
var
  allow: Boolean;
  i: Integer;
begin
  if not FExpanded then
  begin
    allow := True;
    if Assigned(FOwner.FOnExpanding) then FOwner.FOnExpanding(FOwner, Self, allow);
    if not allow then Exit;
    FExpanded := True;
  end;
  if ARecurse then
    for i := 0 to FKids.Count - 1 do TGLTreeNode(FKids[i]).Expand(True);
  FOwner.NodesChanged;
end;

procedure TGLTreeNode.Collapse;
begin
  if not FExpanded then Exit;
  FExpanded := False;
  FOwner.NodesChanged;
end;

{ TGLTreeNodes }

constructor TGLTreeNodes.Create(AOwner: TGLTree);
begin
  inherited Create;
  FOwner := AOwner;
  FRoots := TList.Create;
  FFlat := TList.Create;
end;

destructor TGLTreeNodes.Destroy;
var
  i: Integer;
begin
  for i := 0 to FRoots.Count - 1 do TGLTreeNode(FRoots[i]).Free;
  FRoots.Free;
  FFlat.Free;
  inherited Destroy;
end;

function TGLTreeNodes.AddChild(AParent: TGLTreeNode; const AText: string): TGLTreeNode;
begin
  Result := TGLTreeNode.Create(FOwner, AParent);
  Result.FText := AText;
  if AParent <> nil then AParent.FKids.Add(Result) else FRoots.Add(Result);
  Changed;
end;

procedure TGLTreeNodes.Clear;
var
  i: Integer;
begin
  for i := 0 to FRoots.Count - 1 do TGLTreeNode(FRoots[i]).Free;
  FRoots.Clear;
  FOwner.FSelected := nil;
  Changed;
end;

procedure TGLTreeNodes.BeginUpdate;
begin
  Inc(FUpdating);
end;

procedure TGLTreeNodes.EndUpdate;
begin
  if FUpdating > 0 then Dec(FUpdating);
  if FUpdating = 0 then FOwner.NodesChanged;
end;

procedure TGLTreeNodes.Changed;
begin
  FFlatValid := False;
  if FUpdating = 0 then FOwner.NodesChanged;
end;

procedure TGLTreeNodes.BuildFlat;
  procedure Walk(ANode: TGLTreeNode);
  var
    i: Integer;
  begin
    FFlat.Add(ANode);
    for i := 0 to ANode.FKids.Count - 1 do Walk(TGLTreeNode(ANode.FKids[i]));
  end;
var
  i: Integer;
begin
  FFlat.Clear;
  for i := 0 to FRoots.Count - 1 do Walk(TGLTreeNode(FRoots[i]));
  FFlatValid := True;
end;

function TGLTreeNodes.GetCount: Integer;
begin
  if not FFlatValid then BuildFlat;
  Result := FFlat.Count;
end;

function TGLTreeNodes.GetItem(AIndex: Integer): TGLTreeNode;
begin
  if not FFlatValid then BuildFlat;
  Result := TGLTreeNode(FFlat[AIndex]);
end;

{ TGLTree }

{ the visible body ends 3 px above the control's bottom: that strip holds the drop shadow }
function TGLTree.BodyH: Integer;
begin
  Result := Height - 3;
end;

constructor TGLTree.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  FNodes := TGLTreeNodes.Create(Self);
  FIndent := 19;
  FContentW := -1;
  FHoverIdx := -1;
  Width := 200;
  Height := 150;
  FAnim := TTimer.Create(Self);
  FAnim.Enabled := False;
  FAnim.Interval := 15;
  FAnim.OnTimer := AnimTick;
end;

procedure TGLTree.Kick;
begin
  if (FAnim <> nil) and not (csDesigning in ComponentState) then FAnim.Enabled := True;
end;

{ the display row of the selected node, or -1 }
function TGLTree.SelRow: Integer;
var
  i: Integer;
begin
  Result := -1;
  if FSelected = nil then Exit;
  if not FRowsValid then BuildRows;
  for i := 0 to High(FRows) do
    if FRows[i] = FSelected then Exit(i);
end;

{ the selection pill glides to the chosen row and the hover glow follows the mouse - the same
  easing as the menus and the lists; the timer only runs while something is moving (or the tree
  has focus and its pill is breathing) }
procedure TGLTree.AnimTick(Sender: TObject);
var
  moving: Boolean;
  sr: Integer;
begin
  moving := False;
  sr := SelRow;
  if sr >= 0 then
  begin
    if FPillAlpha < 0.05 then FPillRow := sr;
    FPillRow := FPillRow + (sr - FPillRow) * 0.45;
    if Abs(sr - FPillRow) < 0.01 then FPillRow := sr else moving := True;
    if FPillAlpha < 1 then begin FPillAlpha := System.Math.Min(1, FPillAlpha + 0.25); moving := True; end;
  end
  else if FPillAlpha > 0 then
  begin
    FPillAlpha := System.Math.Max(0, FPillAlpha - 0.2);
    moving := True;
  end;
  if FHoverIdx >= 0 then
  begin
    if FHovAlpha < 0.05 then FHovRow := FHoverIdx;
    FHovRow := FHovRow + (FHoverIdx - FHovRow) * 0.5;
    if Abs(FHoverIdx - FHovRow) < 0.01 then FHovRow := FHoverIdx else moving := True;
    if FHovAlpha < 1 then begin FHovAlpha := System.Math.Min(1, FHovAlpha + 0.3); moving := True; end;
  end
  else if FHovAlpha > 0 then
  begin
    FHovAlpha := System.Math.Max(0, FHovAlpha - 0.25);
    moving := True;
  end;
  FPhase := FPhase + 0.11;
  if (not moving) and not (Focused and (sr >= 0)) then FAnim.Enabled := False;
  Invalidate;
end;

procedure TGLTree.CMMouseLeave(var Msg: TMessage);
begin
  inherited;
  if FHoverIdx <> -1 then
  begin
    FHoverIdx := -1;
    Kick;
  end;
end;

destructor TGLTree.Destroy;
begin
  FNodes.Free;
  inherited Destroy;
end;

procedure TGLTree.WMGetDlgCode(var Msg: TWMGetDlgCode);
begin
  inherited;
  Msg.Result := Msg.Result or DLGC_WANTARROWS;
end;

{ the widest row is measured on paint: showing the tree (or a font change) re-measures it,
  so the bars always match what the container currently shows }
procedure TGLTree.CMVisibleChanged(var Msg: TMessage);
begin
  inherited;
  FContentW := -1;
  FRowsValid := False;
  Invalidate;
end;

procedure TGLTree.CMFontChanged(var Msg: TMessage);
begin
  inherited;
  FContentW := -1;
  Invalidate;
end;

procedure TGLTree.NodesChanged;
begin
  FNodes.FFlatValid := False;
  FRowsValid := False;
  FContentW := -1;
  FTop := EnsureRange(FTop, 0, MaxTop);
  Invalidate;
end;

procedure TGLTree.NodeRemoved(ANode: TGLTreeNode);
var
  n: TGLTreeNode;
begin
  n := FSelected;
  while n <> nil do
  begin
    if n = ANode then
    begin
      FSelected := nil;
      Break;
    end;
    n := n.FParent;
  end;
end;

procedure TGLTree.BuildRows;
var
  list: TList;
  procedure Walk(ANode: TGLTreeNode);
  var
    i: Integer;
  begin
    list.Add(ANode);
    if ANode.FExpanded then
      for i := 0 to ANode.FKids.Count - 1 do Walk(TGLTreeNode(ANode.FKids[i]));
  end;
var
  i: Integer;
begin
  list := TList.Create;
  try
    for i := 0 to FNodes.FRoots.Count - 1 do Walk(TGLTreeNode(FNodes.FRoots[i]));
    SetLength(FRows, list.Count);
    for i := 0 to list.Count - 1 do FRows[i] := TGLTreeNode(list[i]);
  finally
    list.Free;
  end;
  FRowsValid := True;
end;

function TGLTree.RowH: Integer;
begin
  Result := Abs(Font.Height) + 8;
end;

function TGLTree.VisibleRows: Integer;
begin
  Result := System.Math.Max(1, (BodyH - HBarH) div RowH);
end;

{ the horizontal bar shows when the widest row (measured on paint) is wider than the rows' area }
function TGLTree.NeedHBar: Boolean;
var
  vbar: Integer;
begin
  if not FRowsValid then BuildRows;
  if Length(FRows) > System.Math.Max(1, BodyH div RowH) then vbar := 12 else vbar := 0;
  Result := (FContentW > 0) and (FContentW > Width - vbar);
end;

function TGLTree.HBarH: Integer;
begin
  if NeedHBar then Result := 12 else Result := 0;
end;

function TGLTree.MaxLeft: Integer;
var
  vbar: Integer;
begin
  if NeedBar then vbar := 12 else vbar := 0;
  Result := System.Math.Max(0, FContentW - (Width - vbar));
end;

function TGLTree.HThumbRect: TRect;
var
  vbar, track, tw, tx: Integer;
begin
  if NeedBar then vbar := 12 else vbar := 0;
  track := Width - vbar;
  tw := System.Math.Max(20, Round(track * track / System.Math.Max(1, FContentW)));
  if MaxLeft > 0 then tx := Round((track - tw) * FLeft / MaxLeft) else tx := 0;
  Result := Rect(tx, BodyH - 10, tx + tw, BodyH - 2);
end;

procedure TGLTree.SetLeft(AValue: Integer);
begin
  AValue := EnsureRange(AValue, 0, MaxLeft);
  if AValue = FLeft then Exit;
  FLeft := AValue;
  Invalidate;
end;

function TGLTree.MaxTop: Integer;
begin
  if not FRowsValid then BuildRows;
  Result := System.Math.Max(0, Length(FRows) - VisibleRows);
end;

function TGLTree.NeedBar: Boolean;
begin
  if not FRowsValid then BuildRows;
  Result := Length(FRows) > VisibleRows;
end;

function TGLTree.ThumbRect: TRect;
var
  th, ty, track: Integer;
begin
  track := BodyH - HBarH;
  th := System.Math.Max(20, Round(track * VisibleRows / System.Math.Max(1, Length(FRows))));
  if MaxTop > 0 then ty := Round((track - th) * FTop / MaxTop) else ty := 0;
  Result := Rect(Width - 10, ty, Width - 2, ty + th);
end;

procedure TGLTree.Resize;
begin
  inherited Resize;
  FTop := EnsureRange(FTop, 0, MaxTop);
  FLeft := EnsureRange(FLeft, 0, MaxLeft);
end;

procedure TGLTree.SetTop(AValue: Integer);
begin
  AValue := EnsureRange(AValue, 0, MaxTop);
  if AValue = FTop then Exit;
  FTop := AValue;
  Invalidate;
end;

procedure TGLTree.SetSelectedNode(AValue: TGLTreeNode);
var
  n: TGLTreeNode;
  i: Integer;
begin
  FSelected := AValue;
  { reveal it: open every ancestor, then scroll it into view }
  if AValue <> nil then
  begin
    n := AValue.FParent;
    while n <> nil do
    begin
      n.FExpanded := True;
      n := n.FParent;
    end;
    FRowsValid := False;
    FContentW := -1;
    BuildRows;
    for i := 0 to High(FRows) do
      if FRows[i] = AValue then
      begin
        if i < FTop then FTop := i
        else if i >= FTop + VisibleRows then FTop := i - VisibleRows + 1;
        Break;
      end;
  end;
  Invalidate;
end;

function TGLTree.GetNodeAt(X, Y: Integer): TGLTreeNode;
var
  r: Integer;
begin
  if not FRowsValid then BuildRows;
  { the scroll bars are not rows: a click on one must never select or start a drag }
  if (NeedBar and (X >= Width - 12)) or (NeedHBar and (Y >= BodyH - 12)) then Exit(nil);
  r := FTop + Y div RowH;
  if (Y >= 0) and (r >= 0) and (r < Length(FRows)) then Result := FRows[r] else Result := nil;
end;

procedure TGLTree.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  node: TGLTreeNode;
  tr: TRect;
  gx: Integer;
begin
  if (Button = mbLeft) and Enabled then
  begin
    if NeedHBar and (Y >= BodyH - 12) and not (NeedBar and (X >= Width - 12)) then
    begin
      tr := HThumbRect;
      if (X >= tr.Left) and (X < tr.Right) then
      begin
        FHDragging := True;
        FHGrab := X - tr.Left;
        MouseCapture := True;
      end
      else if X < tr.Left then SetLeft(FLeft - Width shr 1)
      else SetLeft(FLeft + Width shr 1);
      inherited MouseDown(Button, Shift, X, Y);
      Exit;
    end;
    if NeedBar and (X >= Width - 12) and (Y < BodyH - HBarH) then
    begin
      tr := ThumbRect;
      if (Y >= tr.Top) and (Y < tr.Bottom) then
      begin
        FDragging := True;
        FGrab := Y - tr.Top;
        MouseCapture := True;
      end
      else if Y < tr.Top then SetTop(FTop - VisibleRows)
      else SetTop(FTop + VisibleRows);
      inherited MouseDown(Button, Shift, X, Y);
      Exit;
    end;
    node := GetNodeAt(X, Y);
    if node <> nil then
    begin
      gx := 4 + node.Level * FIndent - FLeft;
      if (node.Count > 0) and (X >= gx) and (X < gx + FIndent) then
      begin
        if node.Expanded then node.Collapse else node.Expand;
      end;
      SetSelectedNode(node);
    end;
  end;
  inherited MouseDown(Button, Shift, X, Y);
end;

procedure TGLTree.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  room: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if FHDragging then
  begin
    room := Width - (HThumbRect.Right - HThumbRect.Left);
    if NeedBar then Dec(room, 12);
    if room > 0 then SetLeft(Round(MaxLeft * EnsureRange((X - FHGrab) / room, 0, 1)));
    Exit;
  end;
  if not FDragging then
  begin
    room := -1;
    if (Y < BodyH - HBarH) and not (NeedBar and (X >= Width - 12)) then
    begin
      if not FRowsValid then BuildRows;
      room := FTop + Y div RowH;
      if room > High(FRows) then room := -1;
    end;
    if room <> FHoverIdx then
    begin
      FHoverIdx := room;
      Kick;
    end;
    Exit;
  end;
  room := BodyH - HBarH - (ThumbRect.Bottom - ThumbRect.Top);
  if room > 0 then SetTop(Round(MaxTop * EnsureRange((Y - FGrab) / room, 0, 1)));
end;

procedure TGLTree.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if FDragging or FHDragging then MouseCapture := False;
  FDragging := False;
  FHDragging := False;
end;

procedure TGLTree.DblClick;
begin
  inherited DblClick;
  if (FSelected <> nil) and (FSelected.Count > 0) then
    if FSelected.Expanded then FSelected.Collapse else FSelected.Expand;
end;

function TGLTree.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := True;
  if (ssShift in Shift) and NeedHBar then SetLeft(FLeft - Sign(WheelDelta) * 40)
  else SetTop(FTop - Sign(WheelDelta) * 3);
end;

procedure TGLTree.KeyDown(var Key: Word; Shift: TShiftState);
var
  i, idx: Integer;
begin
  inherited KeyDown(Key, Shift);
  if not FRowsValid then BuildRows;
  idx := -1;
  for i := 0 to High(FRows) do
    if FRows[i] = FSelected then idx := i;
  case Key of
    VK_UP: if idx > 0 then SetSelectedNode(FRows[idx - 1]) else if idx < 0 then Exit;
    VK_DOWN:
      if idx < 0 then
      begin
        if Length(FRows) > 0 then SetSelectedNode(FRows[0]);
      end
      else if idx < High(FRows) then SetSelectedNode(FRows[idx + 1]);
    VK_RIGHT:
      if (FSelected <> nil) and (FSelected.Count > 0) then
      begin
        if not FSelected.Expanded then FSelected.Expand
        else SetSelectedNode(FSelected.Item[0]);
      end;
    VK_LEFT:
      if FSelected <> nil then
      begin
        if FSelected.Expanded then FSelected.Collapse
        else if FSelected.Parent <> nil then SetSelectedNode(FSelected.Parent);
      end;
    VK_RETURN:
      if (FSelected <> nil) and (FSelected.Count > 0) then
        if FSelected.Expanded then FSelected.Collapse else FSelected.Expand;
  else
    Exit;
  end;
  Key := 0;
end;

procedure TGLTree.PaintGL;
var
  cv: TGLCanvas;
  face, field: TColor;
  i, y, h, th, gx, barW, mid: Integer;
  node: TGLTreeNode;
  tr: TRect;
  sel: Boolean;
  hb, widest: Integer;
begin
  if not FRowsValid then BuildRows;
  cv := GL;
  face := FaceColor;
  field := FieldColor;
  h := RowH;
  th := cv.TextHeight('Ag');
  { measure the widest row once per change, then settle the scroll positions }
  if FContentW < 0 then
  begin
    widest := 0;
    for i := 0 to High(FRows) do
      widest := System.Math.Max(widest, 4 + FRows[i].Level * FIndent + FIndent + cv.TextWidth(FRows[i].Text) + 8);
    FContentW := widest;
    FTop := EnsureRange(FTop, 0, MaxTop);
    FLeft := EnsureRange(FLeft, 0, MaxLeft);
  end;
  if NeedBar then barW := 12 else barW := 0;
  hb := HBarH;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := BackdropColor;
  cv.FillRect(Rect(0, 0, Width, Height));
  DrawDropShadow(cv, Rect(0, 0, Width, BodyH), 6, 3, 1.4);
  cv.Brush.Color := field;
  cv.FillRect(Rect(0, 0, Width, BodyH));
  { keep the animation running until the pill has reached the selected row }
  i := SelRow;
  if (i >= 0) and ((FPillAlpha < 1) or (Abs(i - FPillRow) > 0.01)) then Kick;
  cv.PushClip(Rect(0, 0, Width - barW, BodyH - hb));
  if FHovAlpha > 0.02 then
  begin
    y := Round((FHovRow - FTop) * h);
    cv.Brush.Color := HoverTint;
    cv.Alpha := 0.10 * FHovAlpha;
    cv.RoundRect(3, y + 1, Width - barW - 3, y + h - 1, 7, 7);
    cv.Alpha := 0.14 * FHovAlpha;
    cv.FillRect(Rect(8, y + 1, Width - barW - 8, y + 2));
    cv.Alpha := 1;
  end;
  if FPillAlpha > 0.02 then
  begin
    y := Round((FPillRow - FTop) * h);
    DrawSelectionPill(cv, Rect(3, y + 1, Width - barW - 3, y + h - 1), SelectionColor, FPillAlpha, FPhase);
  end;
  cv.PopClip;
  y := 0;
  for i := FTop to High(FRows) do
  begin
    if y >= BodyH - hb then Break;
    node := FRows[i];
    sel := node = FSelected;
    gx := 4 + node.Level * FIndent - FLeft;
    if node.Count > 0 then
    begin
      mid := y + h div 2;
      if sel then cv.Brush.Color := SelectionTextColor else cv.Brush.Color := Blend(field, InkColor, 0.65);
      if node.Expanded then
        cv.Polygon([Point(gx + 3, mid - 2), Point(gx + 11, mid - 2), Point(gx + 7, mid + 3)])
      else
        cv.Polygon([Point(gx + 5, mid - 4), Point(gx + 5, mid + 4), Point(gx + 9, mid)]);
    end;
    if sel then cv.Font.Color := SelectionTextColor else cv.Font.Color := Sys(clWindowText);
    cv.PushClip(Rect(0, y, Width - barW, System.Math.Min(y + h, BodyH - hb)));
    cv.TextOut(gx + FIndent, y + (h - th) div 2, node.Text);
    cv.PopClip;
    Inc(y, h);
  end;
  DrawInsetShadow(cv, Rect(0, 0, Width - barW, BodyH - hb), 4);
  if NeedBar then
  begin
    tr := ThumbRect;
    cv.Brush.Color := Blend(field, InkColor, 0.1);
    cv.FillRect(Rect(Width - 12, 0, Width, BodyH - hb));
    GLDrawScrollThumb(cv, Self, 0, tr, True, FDragging, Hover, field, InkColor, AccentColor);
  end;
  if hb > 0 then
  begin
    tr := HThumbRect;
    cv.Brush.Color := Blend(field, InkColor, 0.1);
    cv.FillRect(Rect(0, BodyH - 12, Width, BodyH));
    GLDrawScrollThumb(cv, Self, 1, tr, False, FHDragging, Hover, field, InkColor, AccentColor);
  end;
  cv.Pen.Style := psSolid;
  if Focused then cv.Pen.Color := FocusColor else cv.Pen.Color := Blend(face, InkColor, 0.25);
  cv.Brush.Style := bsClear;
  cv.Rectangle(0, 0, Width, BodyH);
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
end;

{ TGLBevel }

constructor TGLBevel.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := False;
  FShape := bsBox;
  FStyle := bsLowered;
  Width := 50;
  Height := 50;
end;

procedure TGLBevel.SetShape(AValue: TBevelShape);
begin
  FShape := AValue;
  Invalidate;
end;

procedure TGLBevel.SetStyle(AValue: TBevelStyle);
begin
  FStyle := AValue;
  Invalidate;
end;

procedure TGLBevel.PaintGL;
var
  cv: TGLCanvas;
  face, dark, light: TColor;
begin
  cv := GL;
  face := FaceColor;
  dark := Blend(face, InkColor, 0.3);
  light := Blend(face, Sys(clWindow), 0.6);
  if FStyle = bsRaised then
  begin
    cv.Brush.Color := dark;
    dark := light;
    light := cv.Brush.Color;
  end;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := face;
  cv.FillRect(Rect(0, 0, Width, Height));
  case FShape of
    bsTopLine:
      begin
        cv.Brush.Color := dark;
        cv.FillRect(Rect(0, 0, Width, 1));
        cv.Brush.Color := light;
        cv.FillRect(Rect(0, 1, Width, 2));
      end;
    bsBottomLine:
      begin
        cv.Brush.Color := dark;
        cv.FillRect(Rect(0, Height - 2, Width, Height - 1));
        cv.Brush.Color := light;
        cv.FillRect(Rect(0, Height - 1, Width, Height));
      end;
    bsLeftLine:
      begin
        cv.Brush.Color := dark;
        cv.FillRect(Rect(0, 0, 1, Height));
        cv.Brush.Color := light;
        cv.FillRect(Rect(1, 0, 2, Height));
      end;
    bsRightLine:
      begin
        cv.Brush.Color := dark;
        cv.FillRect(Rect(Width - 2, 0, Width - 1, Height));
        cv.Brush.Color := light;
        cv.FillRect(Rect(Width - 1, 0, Width, Height));
      end;
    bsFrame, bsBox:
      { a rounded, three-dimensional box: raised or set into the surface }
      DrawBox3D(cv, Rect(0, 0, Width, Height), face, FStyle = bsRaised, 9);
  end;
end;

{ TGLShineBar }

constructor TGLShineBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := False;
  Width := 200;
  Height := 6;
  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := 30;
  FTimer.OnTimer := Tick;
end;

procedure TGLShineBar.Loaded;
begin
  inherited Loaded;
  FTimer.Enabled := not (csDesigning in ComponentState);
end;

procedure TGLShineBar.Tick(Sender: TObject);
begin
  FPhase := FPhase + 0.11;
  if HandleAllocated and Visible then Invalidate;
end;

procedure TGLShineBar.PaintGL;
var
  cv: TGLCanvas;
  face, accent, deep, bright: TColor;
  mid, sx, k, band: Integer;
begin
  cv := GL;
  face := FaceColor;
  accent := AccentColor;
  deep := Blend(accent, clBlack, 0.55);
  bright := Blend(accent, clWhite, 0.6);
  cv.Pen.Style := psClear;
  cv.Brush.Style := bsSolid;
  cv.Brush.Color := face;
  cv.FillRect(Rect(0, 0, Width, Height));
  mid := Height shr 1;
  { shadow line, accent channel, light line underneath: a raised rail }
  cv.Brush.Color := Blend(face, clBlack, 0.35);
  cv.FillRect(Rect(0, mid - 2, Width, mid - 1));
  cv.Brush.Color := deep;
  cv.FillRect(Rect(0, mid - 1, Width, mid));
  cv.Brush.Color := accent;
  cv.FillRect(Rect(0, mid, Width, mid + 1));
  cv.Brush.Color := Blend(accent, deep, 0.5);
  cv.FillRect(Rect(0, mid + 1, Width, mid + 2));
  cv.Brush.Color := Blend(face, clWhite, 0.3);
  cv.FillRect(Rect(0, mid + 2, Width, mid + 3));
  { the glisten: a slanted band of light sweeping left to right across the rail }
  cv.PushClip(Rect(0, mid - 1, Width, mid + 2));
  band := 56;
  sx := -band + Round(Frac(FPhase / 8.0) * (Width + 2 * band));
  cv.Brush.Color := bright;
  for k := 0 to 3 do
  begin
    cv.Alpha := 0.12 + 0.14 * k;
    cv.Polygon([Point(sx + k * 7 + 6, mid - 1), Point(sx + band - k * 7 + 6, mid - 1),
      Point(sx + band - k * 7 - 6, mid + 2), Point(sx + k * 7 - 6, mid + 2)]);
  end;
  cv.Alpha := 1;
  cv.PopClip;
end;

{ TGLProgress }

constructor TGLProgress.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FMax := 100;
  Width := 160;
  Height := 12;
end;

procedure TGLProgress.SetMin(AValue: Double);
begin
  FMin := AValue;
  Invalidate;
end;

procedure TGLProgress.SetMax(AValue: Double);
begin
  FMax := AValue;
  Invalidate;
end;

procedure TGLProgress.SetPos(AValue: Double);
begin
  if SameValue(FPos, AValue, 1e-12) then Exit;
  FPos := AValue;
  Invalidate;
end;

procedure TGLProgress.SetSegmented(AValue: Boolean);
begin
  if FSegmented = AValue then Exit;
  FSegmented := AValue;
  Invalidate;
end;

procedure TGLProgress.SetVertical(AValue: Boolean);
begin
  if FVertical = AValue then Exit;
  FVertical := AValue;
  if (csDesigning in ComponentState) and not (csLoading in ComponentState) then
    SetBounds(Left, Top, Height, Width);
  Invalidate;
end;

{ the level meter: the track is cut into equal segments with equal gaps, lit from the bottom (or left)
  up to the level. A segment's colour comes from its place on the scale - green, amber from 70 %, red
  from 90 % - and an unlit segment is the same colour, dimmed. }
procedure TGLProgress.PaintSegments(cv: TGLCanvas; AFraction: Double);
const
  SEG_LEN = 5;    // the wanted segment length, px
  SEG_GAP = 2;
  PAD = 2;
var
  len, thick, n, i, lit, a, b: Integer;
  pitch, segLen: Double;
  pos: Double;
  col: TColor;
begin
  if FVertical then begin len := Height - 2 * PAD; thick := Width - 2 * PAD; end
  else begin len := Width - 2 * PAD; thick := Height - 2 * PAD; end;
  if (len < SEG_LEN) or (thick < 2) then Exit;
  n := System.Math.Max(1, (len + SEG_GAP) div (SEG_LEN + SEG_GAP));
  pitch := (len + SEG_GAP) / n;      // every segment advances by the same amount
  segLen := pitch - SEG_GAP;
  lit := Round(AFraction * n);
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  for i := 0 to n - 1 do
  begin
    pos := (i + 1) / n;
    if pos > 0.9 then col := TColor($2828E0)         // red
    else if pos > 0.7 then col := TColor($00A5FF)    // amber
    else col := TColor($40C050);                      // green
    if i >= lit then col := Blend(TrackColor, col, 0.22);
    cv.Brush.Color := col;
    a := PAD + Round(i * pitch);
    b := PAD + Round(i * pitch + segLen);
    if FVertical then cv.FillRect(Rect(PAD, Height - b, PAD + thick, Height - a))
    else cv.FillRect(Rect(a, PAD, b, PAD + thick));
  end;
end;

procedure TGLProgress.PaintGL;
var
  cv: TGLCanvas;
  f: Double;
  n: Integer;
begin
  cv := GL;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  { the four corners outside the rounded track show the colour behind the bar }
  cv.Brush.Color := BackdropColor;
  cv.FillRect(Rect(0, 0, Width, Height));
  cv.Brush.Color := TrackColor;
  cv.RoundRect(0, 0, Width, Height, 6, 6);
  cv.Pen.Style := psSolid;
  cv.Pen.Color := Blend(BackdropColor, InkColor, 0.22);   // faint outline
  cv.Brush.Style := bsClear;
  cv.RoundRect(0, 0, Width, Height, 6, 6);
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  if FMax > FMin then f := EnsureRange((FPos - FMin) / (FMax - FMin), 0, 1) else f := 0;
  if FSegmented then
  begin
    PaintSegments(cv, f);
    Exit;
  end;
  cv.Brush.Color := AccentColor;
  if FVertical then
  begin
    n := Round(Height * f);
    if n > 0 then cv.RoundRect(0, Height - n, Width, Height, 6, 6);
  end
  else
  begin
    n := Round(Width * f);
    if n > 0 then cv.RoundRect(0, 0, n, Height, 6, 6);
  end;
end;

{ TGLTabStrip }

constructor TGLTabStrip.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FTabs := TStringList.Create;
  FHintTexts := TStringList.Create;
  FHoverTab := -1;
  FTint := clNone;
  FMeasure := TBitmap.Create;
  FMeasure.SetSize(8, 8);
  Width := 300;
  Height := 28;
  FAnim := TTimer.Create(Self);
  FAnim.Enabled := False;
  FAnim.Interval := 15;
  FAnim.OnTimer := AnimTick;
end;

{ the active tab's pill glides to a newly chosen tab and a band of light keeps sweeping across it
  (as on the page tabs); the timer stops while the strip is not on screen and PaintGL restarts it }
procedure TGLTabStrip.AnimTick(Sender: TObject);
var
  moving: Boolean;
begin
  moving := (Abs(FGoalL - FPillL) >= 0.5) or (Abs(FGoalR - FPillR) >= 0.5);
  FPillL := FPillL + (FGoalL - FPillL) * 0.32;
  FPillR := FPillR + (FGoalR - FPillR) * 0.32;
  if Abs(FGoalL - FPillL) < 0.5 then FPillL := FGoalL;
  if Abs(FGoalR - FPillR) < 0.5 then FPillR := FGoalR;
  FPhase := FPhase + 0.11;
  if (not moving) and not Showing then FAnim.Enabled := False;
  Invalidate;
end;

destructor TGLTabStrip.Destroy;
begin
  FMeasure.Free;
  FHintTexts.Free;
  FTabs.Free;
  inherited Destroy;
end;

function TGLTabStrip.GetTabs: string;
begin
  Result := StringReplace(Trim(FTabs.Text), sLineBreak, ';', [rfReplaceAll]);
end;

procedure TGLTabStrip.SetTabs(const AValue: string);
begin
  FTabs.Text := StringReplace(AValue, ';', sLineBreak, [rfReplaceAll]);
  FLayoutValid := False;
  Invalidate;
end;

procedure TGLTabStrip.Resize;
begin
  inherited Resize;
  FLayoutValid := False;
end;

{ equal-width tabs share the strip; when a caption needs more, tabs take their natural
  width, and a row that is still too wide scrolls between two arrows }
procedure TGLTabStrip.EnsureLayout;
var
  i, share, total, widest: Integer;
begin
  if FLayoutValid and (FLayoutW = Width) then Exit;
  FMeasure.Canvas.Font.Assign(Font);
  SetLength(FWidths, FTabs.Count);
  total := 0;
  widest := 0;
  for i := 0 to FTabs.Count - 1 do
  begin
    FWidths[i] := FMeasure.Canvas.TextWidth(FTabs[i]) + 24;
    Inc(total, FWidths[i]);
    widest := System.Math.Max(widest, FWidths[i]);
  end;
  share := Width div System.Math.Max(1, FTabs.Count);
  FOver := total > Width;
  if FOver then
  begin
    FMaxScroll := System.Math.Max(0, total - (Width - 2 * TAB_ARROW_W));
    FScroll := EnsureRange(FScroll, 0, FMaxScroll);
  end
  else
  begin
    FScroll := 0;
    FMaxScroll := 0;
    if widest <= share then
      for i := 0 to High(FWidths) do FWidths[i] := share
    else if FTabs.Count > 0 then
      for i := 0 to High(FWidths) do Inc(FWidths[i], (Width - total) div FTabs.Count);
  end;
  FLayoutW := Width;
  FLayoutValid := True;
end;

procedure TGLTabStrip.ScrollBy(ADelta: Integer);
var
  was: Integer;
begin
  EnsureLayout;
  was := FScroll;
  FScroll := EnsureRange(FScroll + ADelta, 0, FMaxScroll);
  if FScroll <> was then Invalidate;
end;

procedure TGLTabStrip.RevealTab(AIndex: Integer);
var
  r: TRect;
begin
  EnsureLayout;
  if (not FOver) or (AIndex < 0) or (AIndex >= FTabs.Count) then Exit;
  r := TabRect(AIndex);
  if r.Left < TAB_ARROW_W then ScrollBy(r.Left - TAB_ARROW_W)
  else if r.Right > Width - TAB_ARROW_W then ScrollBy(r.Right - (Width - TAB_ARROW_W));
end;

function TGLTabStrip.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  EnsureLayout;
  Result := FOver;
  if Result then ScrollBy(-Sign(WheelDelta) * 80);
end;

function TGLTabStrip.GetHints: string;
begin
  Result := StringReplace(Trim(FHintTexts.Text), sLineBreak, ';', [rfReplaceAll]);
end;

procedure TGLTabStrip.SetHints(const AValue: string);
begin
  FHintTexts.Text := StringReplace(AValue, ';', sLineBreak, [rfReplaceAll]);
end;

procedure TGLTabStrip.SetIndex(AValue: Integer);
begin
  if FIndex = AValue then Exit;
  FIndex := AValue;
  RevealTab(FIndex);
  Invalidate;
  if Assigned(FOnChange) then FOnChange(Self);
end;

function TGLTabStrip.TabRect(AIndex: Integer): TRect;
var
  i, x: Integer;
begin
  EnsureLayout;
  x := 0;
  for i := 0 to AIndex - 1 do Inc(x, FWidths[i]);
  if FOver then x := x + TAB_ARROW_W - FScroll;
  Result := Rect(x, 0, x + FWidths[AIndex], Height);
  if FCurved then Dec(Result.Bottom, 4);   // the strip below the tabs holds their shadow
end;

function TGLTabStrip.TabAt(X, Y: Integer): Integer;
var
  i: Integer;
begin
  EnsureLayout;
  if FOver and ((X < TAB_ARROW_W) or (X >= Width - TAB_ARROW_W)) then Exit(-1);
  for i := 0 to FTabs.Count - 1 do
    if PtInRect(TabRect(i), Point(X, Y)) then Exit(i);
  Result := -1;
end;

procedure TGLTabStrip.CMMouseLeave(var Msg: TMessage);
begin
  inherited;
  FHoverTab := -1;
end;

procedure TGLTabStrip.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  t: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  t := TabAt(X, Y);
  if t = FHoverTab then Exit;
  FHoverTab := t;
  if (t >= 0) and (t < FHintTexts.Count) then Hint := FHintTexts[t];
  Application.CancelHint;
  Invalidate;
end;

procedure TGLTabStrip.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  t: Integer;
begin
  inherited MouseUp(Button, Shift, X, Y);
  if (Button = mbLeft) and Enabled then
  begin
    EnsureLayout;
    if FOver and (X < TAB_ARROW_W) then
    begin
      ScrollBy(-80);
      Exit;
    end;
    if FOver and (X >= Width - TAB_ARROW_W) then
    begin
      ScrollBy(80);
      Exit;
    end;
  end;
  t := TabAt(X, Y);
  if (Button = mbLeft) and (t >= 0) and Enabled then SetIndex(t);
end;

procedure TGLTabStrip.PaintGL;
var
  cv: TGLCanvas;
  face, accent, deep: TColor;
  i, k, sx: Integer;
  r, pr: TRect;
  pulse: Double;

  { a tab body with rounded top corners and a square foot: the rounded rectangle runs past the
    bottom edge and is clipped }
  procedure TabBody(const R: TRect; AColor: TColor; AAlpha: Double);
  begin
    cv.PushClip(Rect(R.Left, R.Top, R.Right, R.Bottom - 1));
    cv.Brush.Color := AColor;
    cv.Alpha := AAlpha;
    cv.RoundRect(R.Left, R.Top, R.Right, R.Bottom + 12, 11, 11);
    cv.PopClip;
    cv.Alpha := 1;
  end;

begin
  cv := GL;
  face := FaceColor;
  if not FCurved then
  begin
    { flat tabs }
    cv.Brush.Style := bsSolid;
    cv.Pen.Style := psClear;
    cv.Brush.Color := face;
    cv.FillRect(Rect(0, 0, Width, Height));
    EnsureLayout;
    if FOver then cv.PushClip(Rect(TAB_ARROW_W, 0, Width - TAB_ARROW_W, Height));
    for i := 0 to FTabs.Count - 1 do
    begin
      r := TabRect(i);
      if i = FIndex then cv.Brush.Color := Blend(face, AccentColor, 0.22)
      else if i = FHoverTab then cv.Brush.Color := Blend(face, InkColor, 0.12)
      else cv.Brush.Color := face;
      cv.FillRect(Rect(r.Left, r.Top, r.Right, r.Bottom - 2));
      if i = FIndex then DrawTabRaised(cv, Rect(r.Left, r.Top, r.Right, r.Bottom - 2), 1.0, True)
      else DrawTabSunken(cv, Rect(r.Left, r.Top, r.Right, r.Bottom - 2), IfThen(i = FHoverTab, 0.7, 1.0));
      cv.Font.Color := InkColor;
      cv.TextOut(r.Left + (r.Right - r.Left - cv.TextWidth(FTabs[i])) div 2,
        (Height - cv.TextHeight(FTabs[i])) div 2 - 1, FTabs[i]);
    end;
    if FOver then
    begin
      cv.PopClip;
      PaintTabArrows(cv, Width, Height, FScroll, FMaxScroll, InkColor, face);
    end;
    Exit;
  end;
  accent := TColor($3C7A1E);   { the Timeline tabs are lit dark green, whatever the theme's accent is }
  if FTint <> clNone then accent := FTint;
  deep := Blend(accent, clBlack, 0.38);
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := face;
  cv.FillRect(Rect(0, 0, Width, Height));
  EnsureLayout;
  if FOver then cv.PushClip(Rect(TAB_ARROW_W, 0, Width - TAB_ARROW_W, Height));

  { idle and hovered tabs: curved at the top }
  for i := 0 to FTabs.Count - 1 do
  begin
    if i = FIndex then Continue;
    r := TabRect(i);
    if i = FHoverTab then TabBody(Rect(r.Left + 1, r.Top + 2, r.Right - 1, r.Bottom), Blend(face, InkColor, 0.16), 1)
    else TabBody(Rect(r.Left + 1, r.Top + 2, r.Right - 1, r.Bottom), Blend(face, InkColor, 0.05), 1);
    DrawTabSunken(cv, Rect(r.Left + 1, r.Top + 2, r.Right - 1, r.Bottom), IfThen(i = FHoverTab, 0.7, 1.0),
      Blend(face, InkColor, IfThen(i = FHoverTab, 0.16, 0.05)));
  end;

  { the active tab: a pill that glides from tab to tab, with a halo and a sweep of light }
  if (FIndex >= 0) and (FIndex < FTabs.Count) then
  begin
    r := TabRect(FIndex);
    if (FGoalL <> r.Left + 1) or (FGoalR <> r.Right - 1) or not FPillInit then
    begin
      FGoalL := r.Left + 1;
      FGoalR := r.Right - 1;
      if not FPillInit or (csDesigning in ComponentState) then
      begin
        FPillInit := True;
        FPillL := FGoalL;
        FPillR := FGoalR;
      end;
    end;
    if not FAnim.Enabled and not (csDesigning in ComponentState) then FAnim.Enabled := True;
    pr := Rect(Round(FPillL), r.Top + 2, Round(FPillR), r.Bottom);
    pulse := 0.5 + 0.5 * FastSin(FPhase);
    DrawTabShadow(cv, pr, 1.6);
    TabBody(Rect(pr.Left - 2, pr.Top - 2, pr.Right + 2, pr.Bottom), accent, 0.12 + 0.12 * pulse);
    TabBody(pr, deep, 1);
    TabBody(Rect(pr.Left, pr.Top, pr.Right, pr.Bottom - 2), Blend(accent, clWhite, 0.06 + 0.12 * pulse), 1);
    cv.PushClip(Rect(pr.Left + 2, pr.Top + 1, pr.Right - 2, pr.Top + (pr.Bottom - pr.Top) div 2));
    cv.Brush.Color := clWhite;
    cv.Alpha := 0.14;
    cv.RoundRect(pr.Left + 2, pr.Top + 1, pr.Right - 2, pr.Top + (pr.Bottom - pr.Top) + 10, 9, 9);
    cv.PopClip;
    cv.PushClip(Rect(pr.Left + 2, pr.Top + 1, pr.Right - 2, pr.Bottom - 1));
    sx := pr.Left - 40 + Round(Frac(FPhase / 8.0) * (pr.Right - pr.Left + 80));
    cv.Brush.Color := clWhite;
    for k := 0 to 3 do
    begin
      cv.Alpha := 0.05 + 0.05 * k;
      cv.Polygon([Point(sx + k * 5 + 8, pr.Top), Point(sx + 30 - k * 5 + 8, pr.Top),
        Point(sx + 30 - k * 5 - 4, pr.Bottom), Point(sx + k * 5 - 4, pr.Bottom)]);
    end;
    cv.PopClip;
    cv.Alpha := 1;
    DrawTabRaised(cv, pr, 1.2, False);
  end;

  { captions over everything }
  for i := 0 to FTabs.Count - 1 do
  begin
    r := TabRect(i);
    cv.PushClip(Rect(r.Left + 2, r.Top, r.Right - 2, r.Bottom));
    cv.Font.Color := InkColor;
    cv.TextOut(r.Left + (r.Right - r.Left - cv.TextWidth(FTabs[i])) div 2,
      (r.Bottom - cv.TextHeight(FTabs[i])) div 2 - 1, FTabs[i]);
    cv.PopClip;
  end;
  if FOver then
  begin
    cv.PopClip;
    PaintTabArrows(cv, Width, Height, FScroll, FMaxScroll, InkColor, face);
  end;
end;

{ TGLTrackBar }

constructor TGLTrackBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FThumbLength := 20;
  Step := 1;
  Decimals := 0;
  TGLValueWidget(Self).Max := 10;
end;

function TGLTrackBar.GetIMin: Integer;
begin
  Result := Round(TGLValueWidget(Self).Min);
end;

procedure TGLTrackBar.SetIMin(AValue: Integer);
begin
  TGLValueWidget(Self).Min := AValue;
end;

function TGLTrackBar.GetIMax: Integer;
begin
  Result := Round(TGLValueWidget(Self).Max);
end;

procedure TGLTrackBar.SetIMax(AValue: Integer);
begin
  TGLValueWidget(Self).Max := AValue;
end;

function TGLTrackBar.GetIPos: Integer;
begin
  Result := Round(TGLValueWidget(Self).Position);
end;

procedure TGLTrackBar.SetIPos(AValue: Integer);
begin
  TGLValueWidget(Self).Position := AValue;
end;

{ TGLScrollBar }

constructor TGLScrollBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FMax := 100;
  FSmall := 1;
  FLarge := 1;
  Width := 160;
  Height := 16;
end;

procedure TGLScrollBar.SetParams(APosition, AMin, AMax: Integer);
begin
  FMin := AMin;
  FMax := AMax;
  SetPos(APosition);
  Invalidate;
end;

procedure TGLScrollBar.SetMin(AValue: Integer);
begin
  FMin := AValue;
  SetPos(FPos);
  Invalidate;
end;

procedure TGLScrollBar.SetMax(AValue: Integer);
begin
  FMax := AValue;
  SetPos(FPos);
  Invalidate;
end;

procedure TGLScrollBar.SetPage(AValue: Integer);
begin
  FPage := System.Math.Max(0, AValue);
  SetPos(FPos);
  Invalidate;
end;

function TGLScrollBar.HiPos: Integer;
begin
  if FPage > 0 then Result := System.Math.Max(FMin, FMax - FPage + 1)
  else Result := System.Math.Max(FMin, FMax);
end;

procedure TGLScrollBar.SetPos(AValue: Integer);
begin
  AValue := EnsureRange(AValue, FMin, HiPos);
  if AValue = FPos then Exit;
  FPos := AValue;
  Invalidate;
end;

procedure TGLScrollBar.UserSetPos(AValue: Integer);
var
  was: Integer;
begin
  was := FPos;
  SetPos(AValue);
  if (FPos <> was) and Assigned(FOnChange) then FOnChange(Self);
end;

procedure TGLScrollBar.SetVertical(AValue: Boolean);
begin
  if FVertical = AValue then Exit;
  FVertical := AValue;
  if (csDesigning in ComponentState) and not (csLoading in ComponentState) then
    SetBounds(Left, Top, Height, Width);
  Invalidate;
end;

function TGLScrollBar.GetKind: TScrollBarKind;
begin
  if FVertical then Result := sbVertical else Result := sbHorizontal;
end;

procedure TGLScrollBar.SetKind(AValue: TScrollBarKind);
begin
  FVertical := AValue = sbVertical;
  Invalidate;
end;

function TGLScrollBar.Span: Integer;
begin
  if FVertical then Result := Height else Result := Width;
end;

function TGLScrollBar.ThumbLen: Integer;
var
  total: Integer;
begin
  total := FMax - FMin + 1;
  if (total <= 0) or (FPage <= 0) then Exit(System.Math.Min(Span, System.Math.Max(18, Span div 6)));
  Result := System.Math.Max(18, Round(Span * EnsureRange(FPage / total, 0, 1)));
  Result := System.Math.Min(Result, Span);
end;

function TGLScrollBar.ThumbStart: Integer;
var
  room: Integer;
begin
  room := HiPos - FMin;
  if room <= 0 then Exit(0);
  Result := Round((Span - ThumbLen) * (FPos - FMin) / room);
end;

function TGLScrollBar.Along(X, Y: Integer): Integer;
begin
  if FVertical then Result := Y else Result := X;
end;

procedure TGLScrollBar.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  a, ts: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button <> mbLeft) or not Enabled then Exit;
  a := Along(X, Y);
  ts := ThumbStart;
  if (a >= ts) and (a < ts + ThumbLen) then
  begin
    FDragging := True;
    FGrab := a - ts;
  end
  else if a < ts then UserSetPos(FPos - System.Math.Max(FLarge, FPage))
  else UserSetPos(FPos + System.Math.Max(FLarge, FPage));
end;

procedure TGLScrollBar.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  room: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if not FDragging then Exit;
  room := Span - ThumbLen;
  if room <= 0 then Exit;
  UserSetPos(FMin + Round((HiPos - FMin) * EnsureRange((Along(X, Y) - FGrab) / room, 0, 1)));
end;

procedure TGLScrollBar.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FDragging := False;
end;

function TGLScrollBar.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := True;
  if Enabled then UserSetPos(FPos - Sign(WheelDelta) * System.Math.Max(FSmall, 1) * 3);
end;

procedure TGLScrollBar.PaintGL;
var
  cv: TGLCanvas;
  face: TColor;
  ts, tl: Integer;
begin
  cv := GL;
  face := FaceColor;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := face;
  cv.FillRect(Rect(0, 0, Width, Height));
  cv.Brush.Color := Blend(face, InkColor, 0.07);
  cv.RoundRect(0, 0, Width, Height, 6, 6);
  ts := ThumbStart;
  tl := ThumbLen;
  if FVertical then
    GLDrawScrollThumb(cv, Self, 0, Rect(2, ts + 1, Width - 2, ts + tl - 1), True, FDragging, Hover,
      face, InkColor, AccentColor)
  else
    GLDrawScrollThumb(cv, Self, 1, Rect(ts + 1, 2, ts + tl - 1, Height - 2), False, FDragging, Hover,
      face, InkColor, AccentColor);
end;

{ TGLEdit }

constructor TGLEdit.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  Cursor := crIBeam;
  Width := 140;
  Height := 24;
  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := GetCaretBlinkTime;
  FTimer.OnTimer := Blink;
end;

destructor TGLEdit.Destroy;
begin
  FTimer.Free;
  inherited Destroy;
end;

procedure TGLEdit.Blink(Sender: TObject);
begin
  FCaretOn := not FCaretOn;
  Invalidate;
end;

procedure TGLEdit.WMSetFocus(var Msg: TWMSetFocus);
begin
  inherited;
  FCaretOn := True;
  FTimer.Enabled := True;
  Invalidate;
end;

procedure TGLEdit.WMKillFocus(var Msg: TWMKillFocus);
begin
  inherited;
  FTimer.Enabled := False;
  FCaretOn := False;
  Invalidate;
end;

procedure TGLEdit.WMGetDlgCode(var Msg: TWMGetDlgCode);
begin
  inherited;
  Msg.Result := Msg.Result or DLGC_WANTARROWS or DLGC_WANTCHARS;
end;

function TGLEdit.Shown: string;
begin
  if FPasswordChar <> #0 then Result := StringOfChar(FPasswordChar, Length(FText))
  else Result := FText;
end;

procedure TGLEdit.SetText(const AValue: string);
begin
  if FText = AValue then Exit;
  FText := AValue;
  FCaret := Length(FText);
  FAnchor := FCaret;
  Invalidate;
  Changed;
end;

procedure TGLEdit.SetPasswordChar(AValue: Char);
begin
  FPasswordChar := AValue;
  Invalidate;
end;

procedure TGLEdit.Changed;
begin
  if Assigned(FOnChange) then FOnChange(Self);
end;

procedure TGLEdit.SetCaret(AValue: Integer; AExtend: Boolean);
begin
  FCaret := EnsureRange(AValue, 0, Length(FText));
  if not AExtend then FAnchor := FCaret;
  FCaretOn := True;
  Invalidate;
end;

function TGLEdit.HasSelection: Boolean;
begin
  Result := FCaret <> FAnchor;
end;

procedure TGLEdit.SelectAll;
begin
  FAnchor := 0;
  FCaret := Length(FText);
  Invalidate;
end;

procedure TGLEdit.DeleteSelection;
var
  a, b: Integer;
begin
  a := System.Math.Min(FCaret, FAnchor);
  b := System.Math.Max(FCaret, FAnchor);
  Delete(FText, a + 1, b - a);
  FCaret := a;
  FAnchor := a;
end;

procedure TGLEdit.InsertText(const S: string);
var
  t: string;
  i: Integer;
begin
  if FReadOnly or (S = '') then Exit;
  t := S;
  if FNumbersOnly then
    for i := Length(t) downto 1 do
      if not CharInSet(t[i], ['0'..'9']) then Delete(t, i, 1);
  if HasSelection then DeleteSelection;
  if (FMaxLength > 0) and (Length(FText) + Length(t) > FMaxLength) then
    t := Copy(t, 1, System.Math.Max(0, FMaxLength - Length(FText)));
  if t = '' then Exit;
  Insert(t, FText, FCaret + 1);
  Inc(FCaret, Length(t));
  FAnchor := FCaret;
  FCaretOn := True;
  Invalidate;
  Changed;
end;

{ char index nearest to client X, from the offsets recorded by the last paint }
function TGLEdit.IndexAtX(X: Integer): Integer;
var
  i: Integer;
begin
  X := X - 6 + FScroll;
  Result := Length(FText);
  for i := 0 to Length(FCharX) - 2 do
    if X < (FCharX[i] + FCharX[i + 1]) div 2 then Exit(i);
end;

procedure TGLEdit.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;
  if CanFocus and not Focused then SetFocus;
  SetCaret(IndexAtX(X), ssShift in Shift);
end;

procedure TGLEdit.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseMove(Shift, X, Y);
  if Pressed then SetCaret(IndexAtX(X), True);
end;

procedure TGLEdit.KeyDown(var Key: Word; Shift: TShiftState);
var
  ext: Boolean;
  a, b: Integer;
begin
  inherited KeyDown(Key, Shift);
  ext := ssShift in Shift;
  case Key of
    VK_LEFT: begin SetCaret(FCaret - 1, ext); Key := 0; end;
    VK_RIGHT: begin SetCaret(FCaret + 1, ext); Key := 0; end;
    VK_HOME: begin SetCaret(0, ext); Key := 0; end;
    VK_END: begin SetCaret(Length(FText), ext); Key := 0; end;
    VK_BACK:
      if not FReadOnly then
      begin
        if HasSelection then DeleteSelection
        else if FCaret > 0 then
        begin
          Delete(FText, FCaret, 1);
          Dec(FCaret);
          FAnchor := FCaret;
        end;
        Invalidate;
        Changed;
        Key := 0;
      end;
    VK_DELETE:
      if not FReadOnly then
      begin
        if HasSelection then DeleteSelection
        else if FCaret < Length(FText) then Delete(FText, FCaret + 1, 1);
        Invalidate;
        Changed;
        Key := 0;
      end;
  else
    if ssCtrl in Shift then
      case Key of
        Ord('A'):
          begin
            SelectAll;
            Key := 0;
          end;
        Ord('C'), Ord('X'):
          begin
            if HasSelection and (FPasswordChar = #0) then
            begin
              a := System.Math.Min(FCaret, FAnchor);
              b := System.Math.Max(FCaret, FAnchor);
              Clipboard.AsText := Copy(FText, a + 1, b - a);
              if (Key = Ord('X')) and not FReadOnly then
              begin
                DeleteSelection;
                Invalidate;
                Changed;
              end;
            end;
            Key := 0;
          end;
        Ord('V'):
          begin
            if Clipboard.HasFormat(CF_UNICODETEXT) then
              InsertText(StringReplace(StringReplace(Clipboard.AsText, #13, '', [rfReplaceAll]),
                #10, ' ', [rfReplaceAll]));
            Key := 0;
          end;
      end;
  end;
end;

procedure TGLEdit.KeyPress(var Key: Char);
begin
  inherited KeyPress(Key);
  if Key >= #32 then InsertText(Key);
  Key := #0;
end;

procedure TGLEdit.PaintGL;
var
  cv: TGLCanvas;
  face, field: TColor;
  s: string;
  i, ty, caretX, a, b, inner, bh: Integer;
begin
  if FFlat then bh := Height else bh := Height - 4;   // the field stands off its shadow
  cv := GL;
  face := FaceColor;
  field := FieldColor;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  { corners and the shadow strip show what the field sits on (a title bar, a recessed panel ...) }
  cv.Brush.Color := BackdropColor;
  cv.FillRect(Rect(0, 0, Width, Height));
  cv.Brush.Color := field;
  if FFlat then cv.FillRect(Rect(0, 0, Width, Height))
  else
  begin
    DrawDropShadow(cv, Rect(0, 0, Width, bh), 6, 4, 1.6);
    cv.Brush.Color := field;
    cv.RoundRect(0, 0, Width, bh, 6, 6);
    cv.Pen.Style := psSolid;
    if Focused then cv.Pen.Color := FocusColor
    else cv.Pen.Color := Blend(face, InkColor, IfThen(Hover, 0.4, 0.22));
    cv.Brush.Style := bsClear;
    cv.RoundRect(0, 0, Width, bh, 6, 6);
    cv.Brush.Style := bsSolid;
    cv.Pen.Style := psClear;
    DrawInsetShadow(cv, Rect(1, 1, Width - 1, bh - 1), 3);
  end;

  s := Shown;
  SetLength(FCharX, Length(s) + 1);
  for i := 0 to Length(s) do FCharX[i] := cv.TextWidth(Copy(s, 1, i));
  inner := Width - 12;
  caretX := FCharX[FCaret];
  if caretX - FScroll > inner then FScroll := caretX - inner;
  if caretX - FScroll < 0 then FScroll := caretX;
  if FCharX[Length(s)] - FScroll < inner then FScroll := System.Math.Max(0, FCharX[Length(s)] - inner);

  cv.PushClip(Rect(5, 2, Width - 5, bh - 2));
  ty := (bh - cv.TextHeight('Ag')) div 2;
  if HasSelection then
  begin
    a := System.Math.Min(FCaret, FAnchor);
    b := System.Math.Max(FCaret, FAnchor);
    cv.Brush.Color := Blend(field, AccentColor, 0.55);
    cv.FillRect(Rect(6 + FCharX[a] - FScroll, 3, 6 + FCharX[b] - FScroll, bh - 3));
  end;
  if Enabled then cv.Font.Color := Sys(clWindowText) else cv.Font.Color := InkColor;
  if (s = '') and (FTextHint <> '') and not Focused then
  begin
    cv.Font.Color := Blend(field, Sys(clWindowText), 0.5);
    cv.TextOut(6, ty, FTextHint);
  end
  else cv.TextOut(6 - FScroll, ty, s);
  if Focused and FCaretOn then
  begin
    cv.Brush.Color := Sys(clWindowText);
    cv.FillRect(Rect(6 + caretX - FScroll, 4, 7 + caretX - FScroll, bh - 4));
  end;
  cv.PopClip;
end;

{ TGLComboList }

constructor TGLComboList.CreateFor(ACombo: TGLCombo);
begin
  inherited Create(nil);
  SharedSurface := True;
  FCombo := ACombo;
  FHot := -1;
  FGlowRow := -1;
  ControlStyle := ControlStyle + [csOpaque];
  FAnim := TTimer.Create(Self);
  FAnim.Interval := 20;
  FAnim.OnTimer := AnimTick;
end;

{ fades the highlight in on the row under the pointer and keeps its pulse and sweep moving }
procedure TGLComboList.AnimTick(Sender: TObject);
begin
  if FHot <> FGlowRow then
  begin
    FGlowRow := FHot;
    FGlow := 0;
  end;
  if FGlowRow >= 0 then FGlow := System.Math.Min(1.0, FGlow + 0.18);
  FPhase := FPhase + 0.11;
  if HandleAllocated and Visible then Invalidate;
end;

{ the same look as a hovered button: a breathing halo, a deep accent body, a gloss and a slanted
  band of light sweeping across the row }
procedure TGLComboList.DrawRowGlow(cv: TGLCanvas; const R: TRect; AAccent: TColor);
var
  deep: TColor;
  pulse, sweep: Double;
  sx, k: Integer;
begin
  deep := Blend(AAccent, clBlack, 0.35);
  pulse := 0.5 + 0.5 * FastSin(FPhase);
  cv.Pen.Style := psClear;
  cv.Brush.Style := bsSolid;
  cv.Brush.Color := AAccent;
  cv.Alpha := (0.10 + 0.16 * pulse) * FGlow;
  cv.RoundRect(R.Left - 1, R.Top - 1, R.Right + 1, R.Bottom + 1, 6, 6);
  cv.Alpha := FGlow;
  cv.Brush.Color := deep;
  cv.RoundRect(R.Left, R.Top, R.Right, R.Bottom, 4, 4);
  cv.Brush.Color := Blend(AAccent, clWhite, 0.06 + 0.14 * pulse);
  cv.RoundRect(R.Left, R.Top, R.Right, R.Bottom - 2, 4, 4);
  cv.Brush.Color := clWhite;
  cv.Alpha := 0.14 * FGlow;
  cv.RoundRect(R.Left + 2, R.Top + 1, R.Right - 2, R.Top + (R.Bottom - R.Top) div 2, 2, 2);
  cv.PushClip(Rect(R.Left + 1, R.Top + 1, R.Right - 1, R.Bottom - 1));
  sweep := Frac(FPhase / 8.0);
  sx := R.Left - 40 + Round(sweep * (R.Right - R.Left + 80));
  cv.Brush.Color := clWhite;
  for k := 0 to 3 do
  begin
    cv.Alpha := (0.05 + 0.05 * k) * FGlow;
    cv.Polygon([Point(sx + k * 5 + 8, R.Top), Point(sx + 30 - k * 5 + 8, R.Top),
      Point(sx + 30 - k * 5 - 4, R.Bottom), Point(sx + k * 5 - 4, R.Bottom)]);
  end;
  cv.PopClip;
  cv.Alpha := 1;
end;

procedure TGLComboList.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  Params.Style := (Params.Style and not WS_CHILD) or WS_POPUP;
  Params.ExStyle := Params.ExStyle or WS_EX_TOOLWINDOW or WS_EX_TOPMOST or WS_EX_NOACTIVATE;
  Params.WndParent := GetDesktopWindow;
end;

procedure TGLComboList.Dismiss;
begin
  ShowWindow(Handle, SW_HIDE);
  PostMessage(Handle, CM_RELEASE, 0, 0);
end;

procedure TGLComboList.CMRelease(var Msg: TMessage);
begin
  Free;
end;

procedure TGLComboList.WMMouseActivate(var Msg: TWMMouseActivate);
begin
  Msg.Result := MA_NOACTIVATE;
end;

function TGLComboList.RowAt(Y: Integer): Integer;
begin
  Result := FTop + Y div 22;
  if (Result < 0) or (Result >= FCombo.Items.Count) then Result := -1;
end;

procedure TGLComboList.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  r: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  r := RowAt(Y);
  if PtInRect(ClientRect, Point(X, Y)) and (r <> FHot) then
  begin
    FHot := r;
    Invalidate;
  end;
end;

{ the list holds the mouse capture while open: a click outside closes it }
procedure TGLComboList.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if PtInRect(ClientRect, Point(X, Y)) then
  begin
    if RowAt(Y) >= 0 then FCombo.Pick(RowAt(Y));
  end
  else FCombo.CloseUp;
end;

function TGLComboList.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
var
  vis: Integer;
begin
  Result := True;
  vis := Height div 22;
  FTop := EnsureRange(FTop - Sign(WheelDelta) * 3, 0, System.Math.Max(0, FCombo.Items.Count - vis));
  Invalidate;
end;

procedure TGLComboList.PrepareCanvas(ACanvas: TGLCanvas);
begin
  inherited PrepareCanvas(ACanvas);
  ACanvas.Font.Name := FCombo.Font.Name;
  if FCombo.Font.Height <> 0 then ACanvas.Font.Height := FCombo.Font.Height;
end;

procedure TGLComboList.PaintGL;
var
  cv: TGLCanvas;
  face: TColor;
  i, y: Integer;
begin
  cv := GL;
  face := FCombo.FieldColor;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := face;
  cv.FillRect(Rect(0, 0, Width, Height));
  y := 0;
  for i := FTop to FCombo.Items.Count - 1 do
  begin
    if y >= Height then Break;
    if i = FHot then cv.Brush.Color := Blend(face, FCombo.AccentColor, 0.6)
    else if i = FCombo.ItemIndex then
      cv.Brush.Color := Blend(face, FCombo.AccentColor, 0.25 + 0.10 * (0.5 + 0.5 * FastSin(FPhase)))
    else cv.Brush.Color := face;
    cv.FillRect(Rect(0, y, Width, y + 22));
    if (i = FHot) and (i = FGlowRow) then
      DrawRowGlow(cv, Rect(2, y + 1, Width - 2, y + 21), FCombo.AccentColor);
    cv.Font.Color := FCombo.InkColor;
    cv.TextOut(8, y + (22 - cv.TextHeight('Ag')) div 2, FCombo.Items[i]);
    Inc(y, 22);
  end;
  cv.Pen.Style := psSolid;
  cv.Pen.Color := Blend(face, FCombo.InkColor, 0.3);
  cv.Brush.Style := bsClear;
  cv.Rectangle(0, 0, Width, Height);
  cv.Brush.Style := bsSolid;
end;

{ TGLCombo }

constructor TGLCombo.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FItems := TStringList.Create;
  FIndex := -1;
  FDropRows := 8;
  FStyle := csDropDownList;
  ControlStyle := ControlStyle + [csAcceptsControls];
  TabStop := True;
  Width := 140;
  Height := 24;
end;

destructor TGLCombo.Destroy;
begin
  if Assigned(FList) then
  begin
    FList.Free;
    FList := nil;
  end;
  FItems.Free;
  inherited Destroy;
end;

procedure TGLCombo.SetItems(AValue: TStrings);
begin
  FItems.Assign(AValue);
  if FIndex >= FItems.Count then FIndex := -1;
  Invalidate;
end;

procedure TGLCombo.SetIndex(AValue: Integer);
begin
  if csLoading in ComponentState then
  begin
    FIndex := AValue;
    Exit;
  end;
  AValue := EnsureRange(AValue, -1, FItems.Count - 1);
  if FIndex = AValue then Exit;
  FIndex := AValue;
  if (FEdit <> nil) and (FIndex >= 0) then
  begin
    FSync := True;
    try
      FEdit.Text := FItems[FIndex];
    finally
      FSync := False;
    end;
  end;
  Invalidate;
end;

{ a choice made by the user: also raises OnChange }
procedure TGLCombo.UserSetIndex(AValue: Integer);
var
  was: Integer;
begin
  was := FIndex;
  SetIndex(AValue);
  if (FIndex <> was) and Assigned(FOnChange) then FOnChange(Self);
end;

procedure TGLCombo.Loaded;
begin
  inherited Loaded;
  FIndex := EnsureRange(FIndex, -1, FItems.Count - 1);
end;

function TGLCombo.GetText: string;
begin
  if FEdit <> nil then Result := FEdit.Text
  else if (FIndex >= 0) and (FIndex < FItems.Count) then Result := FItems[FIndex]
  else Result := '';
end;

procedure TGLCombo.SetText(const AValue: string);
var
  i: Integer;
begin
  if FEdit <> nil then FEdit.Text := AValue
  else
  begin
    i := FItems.IndexOf(AValue);
    if i >= 0 then SetIndex(i);
  end;
end;

procedure TGLCombo.SetStyle(AValue: TComboBoxStyle);
begin
  if FStyle = AValue then Exit;
  FStyle := AValue;
  if (FStyle = csDropDown) and (FEdit = nil) then
  begin
    FEdit := TGLEdit.Create(Self);
    FEdit.Flat := True;
    FEdit.Parent := Self;
    FEdit.OnChange := EditChanged;
    if (FIndex >= 0) and (FIndex < FItems.Count) then FEdit.Text := FItems[FIndex];
    Resize;
  end
  else if (FStyle <> csDropDown) and (FEdit <> nil) then FreeAndNil(FEdit);
  Invalidate;
end;

procedure TGLCombo.Resize;
begin
  inherited Resize;
  if FEdit <> nil then FEdit.SetBounds(2, 2, Width - 22, Height - 4 - 4);
end;

{ typing in the box: the matching list entry (if any) becomes the item index }
procedure TGLCombo.EditChanged(Sender: TObject);
begin
  if FSync then Exit;
  FIndex := FItems.IndexOf(FEdit.Text);
  Invalidate;
  if Assigned(FOnChange) then FOnChange(Self);
end;

function TGLCombo.GetListWindow: TWinControl;
begin
  Result := FList;
end;

function TGLCombo.DroppedDown: Boolean;
begin
  Result := Assigned(FList);
end;

procedure TGLCombo.DropDown;
var
  p: TPoint;
  rows, h: Integer;
begin
  if DroppedDown or (FItems.Count = 0) or (csDesigning in ComponentState) then Exit;
  rows := EnsureRange(FItems.Count, 1, System.Math.Max(1, FDropRows));
  h := rows * 22 + 2;
  FList := TGLComboList.CreateFor(Self);
  p := ClientToScreen(Point(0, Height));
  FList.SetBounds(p.X, p.Y, Width, h);
  FList.HandleNeeded;
  SetWindowPos(FList.Handle, HWND_TOPMOST, p.X, p.Y, Width, h, SWP_NOACTIVATE or SWP_SHOWWINDOW);
  SetCapture(FList.Handle);
  Invalidate;
end;

procedure TGLCombo.CloseUp;
var
  l: TGLComboList;
begin
  if not DroppedDown then Exit;
  l := FList;
  FList := nil;
  if GetCapture = l.Handle then ReleaseCapture;
  l.Dismiss;
  Invalidate;
end;

procedure TGLCombo.Pick(AIndex: Integer);
begin
  CloseUp;
  UserSetIndex(AIndex);
  if Assigned(FOnSelect) then FOnSelect(Self);
end;

procedure TGLCombo.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  inside: Boolean;
begin
  inside := Pressed and PtInRect(ClientRect, Point(X, Y));
  inherited MouseUp(Button, Shift, X, Y);
  if (Button = mbLeft) and inside and Enabled then
  begin
    if CanFocus and not Focused then SetFocus;
    if DroppedDown then CloseUp else DropDown;
  end;
end;

function TGLCombo.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := True;
  if Enabled and not DroppedDown then UserSetIndex(FIndex - Sign(WheelDelta));
end;

procedure TGLCombo.PaintGL;
var
  cv: TGLCanvas;
  face: TColor;
  ax, ay, bh: Integer;
begin
  bh := Height - 4;   // the field stands off its shadow
  cv := GL;
  face := FaceColor;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := BackdropColor;
  cv.FillRect(Rect(0, 0, Width, Height));
  DrawDropShadow(cv, Rect(0, 0, Width, bh), 6, 4, 1.6);
  cv.Brush.Color := Blend(FieldColor, InkColor, IfThen(Hover or DroppedDown, 0.1, 0));
  cv.RoundRect(0, 0, Width, bh, 6, 6);
  cv.Pen.Style := psSolid;
  if Focused or DroppedDown then cv.Pen.Color := FocusColor
  else cv.Pen.Color := Blend(face, InkColor, 0.25);
  cv.Brush.Style := bsClear;
  cv.RoundRect(0, 0, Width, bh, 6, 6);
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  DrawInsetShadow(cv, Rect(1, 1, Width - 1, bh - 1), 3);
  if FEdit = nil then
  begin
    cv.PushClip(Rect(4, 1, Width - 20, bh - 1));
    cv.Font.Color := InkColor;
    cv.TextOut(8, (bh - cv.TextHeight('Ag')) div 2, Text);
    cv.PopClip;
  end;
  cv.Brush.Color := InkColor;
  ax := Width - 12;
  ay := bh div 2;
  cv.Polygon([Point(ax - 4, ay - 2), Point(ax + 4, ay - 2), Point(ax, ay + 3)]);
end;

procedure GLAlignLabelsToFields(AParent: TWinControl);
const
  MAX_GAP = 40;   // a label further than this from a field is not its caption
var
  i, j: Integer;
  c, f: TControl;
  lbl: TGLLabel;
  body: Integer;
begin
  if AParent = nil then Exit;
  for i := 0 to AParent.ControlCount - 1 do
  begin
    c := AParent.Controls[i];
    if (c is TGLLabel) and not TGLLabel(c).WordWrap then
    begin
      lbl := TGLLabel(c);
      for j := 0 to AParent.ControlCount - 1 do
      begin
        f := AParent.Controls[j];
        if not ((f is TGLCombo) or (f is TGLEdit)) then Continue;
        if (f is TGLEdit) and TGLEdit(f).Flat then Continue;
        if (f.Left < lbl.Left + lbl.Width - 4) or (f.Left - (lbl.Left + lbl.Width) > MAX_GAP) then Continue;
        if (f.Top >= lbl.Top + lbl.Height) or (lbl.Top >= f.Top + f.Height) then Continue;
        body := f.Height - 4;   // the field's body stands off a 4 px shadow
        lbl.AutoSize := False;
        lbl.Layout := tlCenter;
        lbl.SetBounds(lbl.Left, f.Top, lbl.Width, body);
        Break;
      end;
    end;
    if c is TWinControl then GLAlignLabelsToFields(TWinControl(c));
  end;
end;

initialization
  RegisterClasses([TGLButton, TGLCheck, TGLKnob, TGLSlider, TGLEqSlider, TGLProgress, TGLLabel, TGLGroup, TGLPanel, TGLRecessPanel, TGLList, TGLMemo, TGLColumn, TGLListView, TGLPage, TGLPageControl, TGLTrackBar, TGLBevel, TGLShineBar, TGLSplitter, TGLScrollBox, TGLStatusPanel, TGLStatusBar, TGLTree,
    TGLTabStrip, TGLScrollBar, TGLEdit, TGLCombo]);

end.
