unit UDAW.Timeline.View;
{$I udaw.inc}

{ Phase 7 - Timeline: the editor viewport (zoom, horizontal scroll, snap).

  A GUI-free value holder that maps timeline seconds <-> horizontal pixels and
  quantises positions to the musical grid. The actual painting and the vertical
  (per-track) layout live in the form; keeping the horizontal math here makes
  zoom/scroll/snap unit-testable and identical between the VCL and LCL builds. }

interface

uses
  SysUtils, Math,
  UDAW.Errors,
  UDAW.Timeline.Time;

const
  TIMELINE_VIEW_MIN_PPS = 1.0;        // 1 px per second (fully zoomed out)
  TIMELINE_VIEW_MAX_PPS = 40000.0;    // sub-sample zoom at 48 kHz
  TIMELINE_VIEW_DEFAULT_PPS = 100.0;

type
  TTimelineView = class
  private
    FPixelsPerSecond: Double;
    FScrollSeconds: Double;       // timeline second at x = HeaderWidth
    FHeaderWidth: Integer;        // px reserved on the left for track headers
    FRulerHeight: Integer;        // px reserved on top for the ruler
    FTrackTitleHeight: Integer;   // px, a per-track band (above that track's own content) for section/effect titles
    FViewportWidth: Integer;      // px, whole control
    FContentSeconds: Double;      // total arrangement length, for scroll clamp
    FGrid: TGridContext;
    FSnap: TSnapMode;
    procedure ClampScroll;
  public
    constructor Create;

    procedure SetGrid(const AGrid: TGridContext);
    procedure SetContentSeconds(AValue: Double);
    procedure SetViewportWidth(APixels: Integer);
    procedure SetHeaderWidth(APixels: Integer);
    procedure SetRulerHeight(APixels: Integer);
    procedure SetTrackTitleHeight(APixels: Integer);

    procedure SetZoom(APixelsPerSecond: Double);
    { Multiply the zoom by AFactor keeping the timeline position currently under
      AAnchorX (a pixel x in the control) pinned to that same pixel. }
    procedure ZoomBy(AFactor: Double; AAnchorX: Integer);
    procedure ScrollToSeconds(AValue: Double);
    procedure ScrollBySeconds(ADelta: Double);
    procedure ScrollByPixels(ADelta: Integer);
    { Bring ASeconds inside the visible window (with a small margin). }
    procedure EnsureVisible(ASeconds: Double);

    function SecondsToX(ASeconds: Double): Double;
    function XToSeconds(AX: Double): Double;
    function PixelsToSeconds(APixels: Double): Double;
    function SecondsToPixels(ASeconds: Double): Double;

    function VisibleStartSeconds: Double;
    function VisibleEndSeconds: Double;
    function MaxScrollSeconds: Double;

    function SnapEnabled: Boolean;
    function Snap(ASeconds: Double): Double;
    function SnapDir(ASeconds: Double; ADir: Integer): Double;

    property PixelsPerSecond: Double read FPixelsPerSecond;
    property ScrollSeconds: Double read FScrollSeconds;
    property HeaderWidth: Integer read FHeaderWidth write SetHeaderWidth;
    property RulerHeight: Integer read FRulerHeight write SetRulerHeight;
    { per-track band, drawn above that track's own header/lane content, for
      that channel's section/effect-name title - see TTimelineTrack.Title }
    property TrackTitleHeight: Integer read FTrackTitleHeight write SetTrackTitleHeight;
    property ViewportWidth: Integer read FViewportWidth;
    property ContentSeconds: Double read FContentSeconds;
    property Grid: TGridContext read FGrid;
    property SnapMode: TSnapMode read FSnap write FSnap;
  end;

implementation

constructor TTimelineView.Create;
begin
  inherited Create;
  FPixelsPerSecond := TIMELINE_VIEW_DEFAULT_PPS;
  FScrollSeconds := 0;
  FHeaderWidth := 160;
  FRulerHeight := 28;
  FTrackTitleHeight := 14;
  FViewportWidth := 800;
  FContentSeconds := 0;
  FGrid := TGridContext.Make(120, 4, 4, 48000);
  FSnap := smBeat;
end;

procedure TTimelineView.SetGrid(const AGrid: TGridContext);
begin
  FGrid := AGrid;
end;

procedure TTimelineView.SetContentSeconds(AValue: Double);
begin
  if AValue < 0 then AValue := 0;
  FContentSeconds := AValue;
  ClampScroll;
end;

procedure TTimelineView.SetViewportWidth(APixels: Integer);
begin
  if APixels < 0 then APixels := 0;
  FViewportWidth := APixels;
  ClampScroll;
end;

procedure TTimelineView.SetHeaderWidth(APixels: Integer);
begin
  if APixels < 0 then APixels := 0;
  FHeaderWidth := APixels;
end;

procedure TTimelineView.SetRulerHeight(APixels: Integer);
begin
  if APixels < 0 then APixels := 0;
  FRulerHeight := APixels;
end;

procedure TTimelineView.SetTrackTitleHeight(APixels: Integer);
begin
  if APixels < 0 then APixels := 0;
  FTrackTitleHeight := APixels;
end;

function TTimelineView.MaxScrollSeconds: Double;
var
  laneW: Integer;
  visibleSpan: Double;
begin
  laneW := FViewportWidth - FHeaderWidth;
  if laneW < 1 then laneW := 1;
  visibleSpan := laneW / FPixelsPerSecond;
  Result := FContentSeconds - visibleSpan;
  { give a screen of run-out room past the end of the content }
  if Result < 0 then Result := 0;
  Result := Result + visibleSpan * 0.25;
end;

procedure TTimelineView.ClampScroll;
begin
  if FScrollSeconds < 0 then FScrollSeconds := 0;
  if FScrollSeconds > MaxScrollSeconds then FScrollSeconds := MaxScrollSeconds;
  if FScrollSeconds < 0 then FScrollSeconds := 0;
end;

procedure TTimelineView.SetZoom(APixelsPerSecond: Double);
begin
  if APixelsPerSecond < TIMELINE_VIEW_MIN_PPS then APixelsPerSecond := TIMELINE_VIEW_MIN_PPS;
  if APixelsPerSecond > TIMELINE_VIEW_MAX_PPS then APixelsPerSecond := TIMELINE_VIEW_MAX_PPS;
  FPixelsPerSecond := APixelsPerSecond;
  ClampScroll;
end;

procedure TTimelineView.ZoomBy(AFactor: Double; AAnchorX: Integer);
var
  anchorSec, oldPps: Double;
begin
  if AFactor <= 0 then Exit;
  anchorSec := XToSeconds(AAnchorX);
  oldPps := FPixelsPerSecond;
  SetZoom(FPixelsPerSecond * AFactor);
  if FPixelsPerSecond = oldPps then Exit;
  { keep anchorSec under AAnchorX: solve scroll from SecondsToX(anchorSec) = AAnchorX }
  FScrollSeconds := anchorSec - (AAnchorX - FHeaderWidth) / FPixelsPerSecond;
  ClampScroll;
end;

procedure TTimelineView.ScrollToSeconds(AValue: Double);
begin
  FScrollSeconds := AValue;
  ClampScroll;
end;

procedure TTimelineView.ScrollBySeconds(ADelta: Double);
begin
  ScrollToSeconds(FScrollSeconds + ADelta);
end;

procedure TTimelineView.ScrollByPixels(ADelta: Integer);
begin
  ScrollToSeconds(FScrollSeconds + ADelta / FPixelsPerSecond);
end;

procedure TTimelineView.EnsureVisible(ASeconds: Double);
var
  margin: Double;
begin
  margin := 0.05 * (VisibleEndSeconds - VisibleStartSeconds);
  if ASeconds < VisibleStartSeconds + margin then
    ScrollToSeconds(ASeconds - margin)
  else if ASeconds > VisibleEndSeconds - margin then
    ScrollToSeconds(FScrollSeconds + (ASeconds - (VisibleEndSeconds - margin)));
end;

function TTimelineView.SecondsToX(ASeconds: Double): Double;
begin
  Result := FHeaderWidth + (ASeconds - FScrollSeconds) * FPixelsPerSecond;
end;

function TTimelineView.XToSeconds(AX: Double): Double;
begin
  Result := FScrollSeconds + (AX - FHeaderWidth) / FPixelsPerSecond;
end;

function TTimelineView.PixelsToSeconds(APixels: Double): Double;
begin
  Result := APixels / FPixelsPerSecond;
end;

function TTimelineView.SecondsToPixels(ASeconds: Double): Double;
begin
  Result := ASeconds * FPixelsPerSecond;
end;

function TTimelineView.VisibleStartSeconds: Double;
begin
  Result := FScrollSeconds;
end;

function TTimelineView.VisibleEndSeconds: Double;
var
  laneW: Integer;
begin
  laneW := FViewportWidth - FHeaderWidth;
  if laneW < 1 then laneW := 1;
  Result := FScrollSeconds + laneW / FPixelsPerSecond;
end;

function TTimelineView.SnapEnabled: Boolean;
begin
  Result := FSnap <> smOff;
end;

function TTimelineView.Snap(ASeconds: Double): Double;
begin
  Result := SnapSeconds(FGrid, ASeconds, FSnap);
end;

function TTimelineView.SnapDir(ASeconds: Double; ADir: Integer): Double;
begin
  Result := SnapSecondsDir(FGrid, ASeconds, FSnap, ADir);
end;

end.
