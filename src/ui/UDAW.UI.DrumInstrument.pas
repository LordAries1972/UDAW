unit UDAW.UI.DrumInstrument;

{ One drum-machine instrument as a collapsible panel: its title bar carries the pad's
  note and name in the pad's own colour, and inside are the pad's name, level, pan,
  mute, solo, choke group, play mode and a graph of the sound assigned to it. The panel
  holds no audio - the main form feeds it the pad's state and the waveform overview
  (the same overview that is saved in the project), and reads the controls back through
  OnChanged. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Math, System.Types, System.UITypes,
  Vcl.Controls, Vcl.Graphics, Vcl.Themes, UDAW.GL.Canvas, UDAW.GL.Controls, UDAW.GL.Widgets;

const
  DRUM_PANEL_W = 372;
  DRUM_PANEL_H = 212;

type
  TDrumInstrumentPanel = class(TGLCollapsePanel)
  private
    FNote: Integer;
    FBusy: Boolean;
    FSelected: Boolean;
    FMissing: Boolean;
    FInfo: string;
    FPeaks: TArray<SmallInt>;
    FPeakScale: Integer;
    FLblName, FLblLevel, FLblPan, FLblChoke: TGLLabel;
    FEdName: TGLEdit;
    FSldLevel, FSldPan: TGLSlider;
    FChkMute, FChkSolo: TGLCheck;
    FCboChoke, FCboMode: TGLCombo;
    FWave: TGLView;
    FBtnPlay, FBtnStop, FBtnLoad, FBtnRemove: TGLIconBar;
    FOnPlay: TNotifyEvent;
    FOnStop: TNotifyEvent;
    FOnChanged: TNotifyEvent;
    FOnLoad: TNotifyEvent;
    FOnClear: TNotifyEvent;
    FOnSelect: TNotifyEvent;
    FOnEdit: TNotifyEvent;
    function GetPadName: string;
    function GetLevel: Double;
    function GetPan: Double;
    function GetMuted: Boolean;
    function GetSoloed: Boolean;
    function GetChoke: Integer;
    function GetMode: Integer;
    procedure SetSelected(AValue: Boolean);
    procedure ControlChanged(Sender: TObject);
    procedure ToolClick(Sender: TObject; AIndex: Integer; const AId: string);
    procedure WavePaint(Sender: TObject);
    procedure ControlEnter(Sender: TObject);
    procedure WaveDblClick(Sender: TObject);
    procedure RaiseEdit;
  protected
    procedure PaintGL; override;
    procedure DblClick; override;
  public
    constructor CreateForNote(AOwner: TComponent; ANote: Integer);
    { fills the controls without raising OnChanged }
    procedure SetState(const AName: string; ALevel, APan: Double; AMuted, ASoloed: Boolean;
      AChoke, AMode: Integer);
    { the waveform overview: min / max pairs scaled by AScale, and a line of text about the sound }
    procedure SetWave(const APeaks: TArray<SmallInt>; AScale: Integer; const AInfo: string;
      AMissing: Boolean);
    property Note: Integer read FNote;
    property PadName: string read GetPadName;
    property Level: Double read GetLevel;
    property Pan: Double read GetPan;
    property Muted: Boolean read GetMuted;
    property Soloed: Boolean read GetSoloed;
    property Choke: Integer read GetChoke;
    property Mode: Integer read GetMode;
    property Selected: Boolean read FSelected write SetSelected;
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
    property OnPlay: TNotifyEvent read FOnPlay write FOnPlay;
    property OnStop: TNotifyEvent read FOnStop write FOnStop;
    property OnLoad: TNotifyEvent read FOnLoad write FOnLoad;
    property OnClear: TNotifyEvent read FOnClear write FOnClear;
    property OnSelect: TNotifyEvent read FOnSelect write FOnSelect;
    { a double-click on the panel (outside its other controls): open the instrument editor }
    property OnEdit: TNotifyEvent read FOnEdit write FOnEdit;
  end;

implementation

function Mix(A, B: TColor; T: Double): TColor;
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

function ThemeColor(AColor: TColor): TColor;
begin
  Result := ColorToRGB(StyleServices.GetSystemColor(AColor));
end;

constructor TDrumInstrumentPanel.CreateForNote(AOwner: TComponent; ANote: Integer);

  function MakeLabel(const ACaption: string; ALeft, ATop, AWidth: Integer): TGLLabel;
  begin
    Result := TGLLabel.Create(Self);
    Result.Parent := Self;
    Result.Transparent := True;
    Result.SetBounds(ALeft, ATop, AWidth, 15);
    Result.Caption := ACaption;
  end;

  function MakeTool(const AIcon, AHint: string; ALeft, ATop: Integer): TGLIconBar;
  begin
    Result := TGLIconBar.Create(Self);
    Result.Parent := Self;
    Result.SetBounds(ALeft, ATop, 34, 28);
    Result.CellWidth := 34;
    Result.ShowHint := True;
    Result.Buttons := AIcon;
    Result.Hints := AHint;
    Result.OnButtonClick := ToolClick;
  end;

begin
  inherited Create(AOwner);
  FNote := ANote;
  FPeakScale := 1000;
  CollapseMode := cmStrip;
  AutoPlace := False;
  SetBounds(0, 0, DRUM_PANEL_W, DRUM_PANEL_H);

  { the controls run down the left side: play, stop, load another sound, remove }
  FBtnPlay := MakeTool('play', 'Play this instrument', 6, 36);
  FBtnStop := MakeTool('stop', 'Stop this instrument', 6, 66);
  FBtnLoad := MakeTool('add', 'Load a different WAV sample into this instrument', 6, 96);
  FBtnRemove := MakeTool('erase', 'Remove this instrument from the kit', 6, 126);

  FLblName := MakeLabel('Name', 50, 44, 40);
  FEdName := TGLEdit.Create(Self);
  FEdName.Parent := Self;
  FEdName.SetBounds(92, 40, 270, 24);
  FEdName.TextHint := 'Instrument name';
  FEdName.OnChange := ControlChanged;
  FEdName.OnEnter := ControlEnter;

  FLblLevel := MakeLabel('Level', 50, 80, 40);
  FSldLevel := TGLSlider.Create(Self);
  FSldLevel.Parent := Self;
  FSldLevel.SetBounds(92, 74, 100, 26);
  FSldLevel.Min := 0;
  FSldLevel.Max := 2;
  FSldLevel.Position := 1;
  FSldLevel.DefaultPosition := 1;
  FSldLevel.Decimals := 2;
  FSldLevel.ShowHint := True;
  FSldLevel.Hint := 'Instrument level (double-click resets to 1.00)';
  FSldLevel.OnChange := ControlChanged;

  FLblPan := MakeLabel('Pan', 200, 80, 26);
  FSldPan := TGLSlider.Create(Self);
  FSldPan.Parent := Self;
  FSldPan.SetBounds(228, 74, 134, 26);
  FSldPan.Min := -1;
  FSldPan.Max := 1;
  FSldPan.Position := 0;
  FSldPan.Decimals := 2;
  FSldPan.ShowHint := True;
  FSldPan.Hint := 'Instrument pan (double-click centres it)';
  FSldPan.OnChange := ControlChanged;

  FChkMute := TGLCheck.Create(Self);
  FChkMute.Parent := Self;
  FChkMute.SetBounds(50, 108, 58, 19);
  FChkMute.Caption := 'Mute';
  FChkMute.ShowHint := True;
  FChkMute.Hint := 'Silence this instrument';
  FChkMute.OnChange := ControlChanged;

  FChkSolo := TGLCheck.Create(Self);
  FChkSolo.Parent := Self;
  FChkSolo.SetBounds(110, 108, 52, 19);
  FChkSolo.Caption := 'Solo';
  FChkSolo.ShowHint := True;
  FChkSolo.Hint := 'Play only the soloed instruments';
  FChkSolo.OnChange := ControlChanged;

  FLblChoke := MakeLabel('Choke', 168, 110, 40);
  FCboChoke := TGLCombo.Create(Self);
  FCboChoke.Parent := Self;
  FCboChoke.SetBounds(210, 106, 70, 24);
  FCboChoke.Items.CommaText := 'Off,Group 1,Group 2,Group 3,Group 4,Group 5,Group 6,Group 7,Group 8';
  FCboChoke.ItemIndex := 0;
  FCboChoke.ShowHint := True;
  FCboChoke.Hint := 'Instruments in the same group cut each other off (open and closed hi-hat)';
  FCboChoke.OnChange := ControlChanged;

  FCboMode := TGLCombo.Create(Self);
  FCboMode.Parent := Self;
  FCboMode.SetBounds(286, 106, 76, 24);
  FCboMode.Items.CommaText := 'One-shot,Gate';
  FCboMode.ItemIndex := 0;
  FCboMode.ShowHint := True;
  FCboMode.Hint := 'One-shot plays the whole sample; Gate stops when the note is released';
  FCboMode.OnChange := ControlChanged;

  FWave := TGLView.Create(Self);
  FWave.Parent := Self;
  FWave.SetBounds(50, 140, DRUM_PANEL_W - 60, 62);
  FWave.OnPaint := WavePaint;
  FWave.OnDblClick := WaveDblClick;
end;

procedure TDrumInstrumentPanel.RaiseEdit;
begin
  if Assigned(FOnSelect) then FOnSelect(Self);
  if Assigned(FOnEdit) then FOnEdit(Self);
end;

procedure TDrumInstrumentPanel.WaveDblClick(Sender: TObject);
begin
  RaiseEdit;
end;

{ the title bar's collapse arrow toggles on a click, so a double-click there is not an edit }
procedure TDrumInstrumentPanel.DblClick;
var
  p: TPoint;
begin
  inherited DblClick;
  p := ScreenToClient(Mouse.CursorPos);
  if Collapsed or ((p.Y < 34) and (p.X > Width - 40)) then Exit;
  RaiseEdit;
end;

procedure TDrumInstrumentPanel.PaintGL;
var
  cv: TGLCanvas;
begin
  inherited PaintGL;
  { the selected instrument gets an outline in the highlight colour }
  if FSelected then
  begin
    cv := GL;
    cv.Pen.Style := psSolid;
    cv.Pen.Color := ThemeColor(clHighlight);
    cv.Pen.Width := 2;
    cv.Brush.Style := bsClear;
    cv.RoundRect(1, 1, Width - 1, Height - 1, 11, 11);
    cv.Pen.Width := 1;
    cv.Pen.Style := psClear;
    cv.Brush.Style := bsSolid;
  end;
end;

function TDrumInstrumentPanel.GetPadName: string;
begin
  Result := FEdName.Text;
end;

function TDrumInstrumentPanel.GetLevel: Double;
begin
  Result := FSldLevel.Position;
end;

function TDrumInstrumentPanel.GetPan: Double;
begin
  Result := FSldPan.Position;
end;

function TDrumInstrumentPanel.GetMuted: Boolean;
begin
  Result := FChkMute.Checked;
end;

function TDrumInstrumentPanel.GetSoloed: Boolean;
begin
  Result := FChkSolo.Checked;
end;

function TDrumInstrumentPanel.GetChoke: Integer;
begin
  Result := Max(0, FCboChoke.ItemIndex);
end;

function TDrumInstrumentPanel.GetMode: Integer;
begin
  Result := Max(0, FCboMode.ItemIndex);
end;

procedure TDrumInstrumentPanel.SetSelected(AValue: Boolean);
begin
  if FSelected = AValue then Exit;
  FSelected := AValue;
  Invalidate;
end;

procedure TDrumInstrumentPanel.SetState(const AName: string; ALevel, APan: Double;
  AMuted, ASoloed: Boolean; AChoke, AMode: Integer);
begin
  FBusy := True;
  try
    if not FEdName.Focused then FEdName.Text := AName;
    FSldLevel.Position := ALevel;
    FSldPan.Position := APan;
    FChkMute.Checked := AMuted;
    FChkSolo.Checked := ASoloed;
    FCboChoke.ItemIndex := EnsureRange(AChoke, 0, FCboChoke.Items.Count - 1);
    FCboMode.ItemIndex := EnsureRange(AMode, 0, 1);
  finally
    FBusy := False;
  end;
end;

procedure TDrumInstrumentPanel.SetWave(const APeaks: TArray<SmallInt>; AScale: Integer;
  const AInfo: string; AMissing: Boolean);
begin
  FPeaks := APeaks;
  FPeakScale := Max(1, AScale);
  FInfo := AInfo;
  FMissing := AMissing;
  FWave.Invalidate;
end;

procedure TDrumInstrumentPanel.ControlChanged(Sender: TObject);
begin
  if FBusy then Exit;
  if Assigned(FOnSelect) then FOnSelect(Self);
  if Assigned(FOnChanged) then FOnChanged(Self);
end;

procedure TDrumInstrumentPanel.ControlEnter(Sender: TObject);
begin
  if Assigned(FOnSelect) then FOnSelect(Self);
end;

procedure TDrumInstrumentPanel.ToolClick(Sender: TObject; AIndex: Integer; const AId: string);
begin
  if Assigned(FOnSelect) then FOnSelect(Self);
  if (AId = 'play') and Assigned(FOnPlay) then FOnPlay(Self)
  else if (AId = 'stop') and Assigned(FOnStop) then FOnStop(Self)
  else if (AId = 'add') and Assigned(FOnLoad) then FOnLoad(Self)
  else if (AId = 'erase') and Assigned(FOnClear) then FOnClear(Self);
end;

{ the sound graph: the overview drawn in the pad's colour on a recessed field }
procedure TDrumInstrumentPanel.WavePaint(Sender: TObject);
var
  cv: TGLCanvas;
  w, h, x, mid, n, k: Integer;
  face, ink, wc: TColor;
  lo, hi: Double;
begin
  cv := FWave.GL;
  w := FWave.Width;
  h := FWave.Height;
  face := ThemeColor(clBtnFace);
  ink := ThemeColor(clBtnText);
  if HeadColor <> clNone then wc := HeadColor else wc := ThemeColor(clHighlight);
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := Mix(face, clBlack, 0.35);
  cv.FillRect(Rect(0, 0, w, h));
  mid := h div 2;
  cv.Brush.Color := Mix(face, ink, 0.25);
  cv.FillRect(Rect(0, mid, w, mid + 1));
  n := Length(FPeaks) shr 1;
  cv.Font.Size := 8;
  if n = 0 then
  begin
    cv.Brush.Style := bsClear;
    cv.Font.Color := Mix(face, ink, 0.55);
    cv.TextOut(8, mid - 7, 'no sound assigned');
    Exit;
  end;
  cv.Pen.Style := psSolid;
  cv.Pen.Color := wc;
  for x := 0 to w - 1 do
  begin
    k := EnsureRange(x * n div Max(1, w), 0, n - 1);
    lo := FPeaks[k * 2] / FPeakScale;
    hi := FPeaks[k * 2 + 1] / FPeakScale;
    cv.MoveTo(x, mid - Round(hi * (mid - 3)));
    cv.LineTo(x, mid - Round(lo * (mid - 3)) + 1);
  end;
  cv.Pen.Style := psClear;
  cv.Brush.Style := bsClear;
  if FMissing then cv.Font.Color := ThemeColor(clRed) else cv.Font.Color := Mix(face, ink, 0.7);
  if FInfo <> '' then cv.TextOut(Max(4, w - 8 - cv.TextWidth(FInfo)), 3, FInfo);
end;

end.
